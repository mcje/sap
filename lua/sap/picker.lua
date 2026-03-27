local buffer = require("sap.buffer")
local config = require("sap.config")
local fs = require("sap.fs")

local M = {}

---@return integer bufnr
---@return integer linenr
---@return State? state
---@return Entry? entry
local function get_context()
    local bufnr = vim.api.nvim_get_current_buf()
    local linenr = vim.api.nvim_win_get_cursor(0)[1]
    local state = buffer.get_state(bufnr)
    local entry = buffer.get_entry_at_line(bufnr, linenr)
    return bufnr, linenr, state, entry
end

--- Open file picker
---@param opts PickerOpts
function M.open(opts)
    opts = opts or {}
    opts.mode = opts.mode or "open"
    opts.multiple = opts.multiple or false
    opts.quit_on_confirm = opts.quit_on_confirm or (opts.output_file ~= nil)

    local path = opts.initial_path and vim.fs.dirname(opts.initial_path) or vim.fn.getcwd()

    local bufnr, err = buffer.create(path, opts)
    if not bufnr then
        vim.notify("sap picker: " .. (err or "failed to create buffer"), vim.log.levels.ERROR)
        return
    end

    -- Setup picker-specific keymaps
    M.setup_keymaps(bufnr)

    vim.api.nvim_set_current_buf(bufnr)

    -- In save mode, highlight and jump to suggested file if it exists
    if opts.mode == "save" and opts.initial_path then
        M.highlight_suggested(bufnr, opts.initial_path)
    end
end

--- Highlight the suggested save file and move cursor to it
---@param bufnr integer
---@param initial_path string
function M.highlight_suggested(bufnr, initial_path)
    local state = buffer.get_state(bufnr)
    if not state then
        return
    end

    local target_name = vim.fs.basename(initial_path)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local parser = require("sap.parser")

    for i, line in ipairs(lines) do
        local id = parser.parse_line(line)
        if id then
            local entry = state:get_by_id(id)
            if entry and entry.name == target_name then
                -- Store the suggested entry ID for later detection
                state.suggested_entry_id = id

                -- Move cursor to this line
                vim.api.nvim_win_set_cursor(0, { i, 0 })

                -- Add virtual text indicator
                local ns = vim.api.nvim_create_namespace("sap_picker_suggested")
                vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
                    virt_text = { { " ← save here", "Comment" } },
                    virt_text_pos = "eol",
                })
                return
            end
        end
    end
end

--- Setup picker keymaps for a buffer
---@param bufnr integer
function M.setup_keymaps(bufnr)
    local picker_cfg = config.options.picker
    if picker_cfg and picker_cfg.keymaps then
        for _, km in ipairs(picker_cfg.keymaps) do
            local mode = km.mode or "n"
            vim.keymap.set(mode, km[1], km[2], { buffer = bufnr, desc = km.desc })
        end
    end
end

--- Toggle mark on current entry
function M.toggle_mark()
    local bufnr, linenr, state, entry = get_context()
    if not state or not state.picker_opts then
        return
    end
    if not entry or not entry.id then
        return
    end

    -- In single-select mode, clear other marks first
    if not state.picker_opts.multiple then
        state.marked = {}
    end

    state:toggle_mark(entry)

    -- Trigger redraw for decoration provider
    vim.cmd("redraw!")
end

--- Toggle mark and move cursor down
function M.toggle_mark_down()
    M.toggle_mark()
    vim.cmd("normal! j")
end

--- Confirm selection and exit
function M.confirm()
    local bufnr, _, state, entry = get_context()
    if not state or not state.picker_opts then
        return
    end

    local opts = state.picker_opts

    -- Save mode has special handling
    if opts.mode == "save" then
        M.confirm_save(bufnr, state, entry, opts)
        return
    end

    -- Open/open_dir modes: use marked entries or cursor entry
    local marked = state:get_marked_entries()
    if #marked == 0 and entry then
        marked = { entry }
    end

    if #marked == 0 then
        vim.notify("sap picker: nothing selected", vim.log.levels.WARN)
        return
    end

    -- Validate and collect paths
    local paths = {}
    for _, e in ipairs(marked) do
        if opts.mode == "open_dir" and e.type ~= "directory" then
            vim.notify("sap picker: must select directories", vim.log.levels.WARN)
            return
        end
        paths[#paths + 1] = e.path
    end

    M.finish(paths, opts, bufnr)
end

--- Show floating confirmation dialog
---@param prompt string
---@param callback function(confirmed: boolean)
local function confirm_dialog(prompt, callback)
    local buf = vim.api.nvim_create_buf(false, true)
    local width = math.max(#prompt + 4, 24)
    local height = 1

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = " " .. prompt .. " ",
        title_pos = "center",
    })

    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "  [Y]es  [N]o" })
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].modifiable = false

    local closed = false
    local function close(result)
        if closed then
            return
        end
        closed = true
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
        vim.schedule(function()
            callback(result)
        end)
    end

    vim.keymap.set("n", "y", function() close(true) end, { buffer = buf })
    vim.keymap.set("n", "Y", function() close(true) end, { buffer = buf })
    vim.keymap.set("n", "n", function() close(false) end, { buffer = buf })
    vim.keymap.set("n", "N", function() close(false) end, { buffer = buf })
    vim.keymap.set("n", "<CR>", function() close(true) end, { buffer = buf })
    vim.keymap.set("n", "<Esc>", function() close(false) end, { buffer = buf })
    vim.keymap.set("n", "q", function() close(false) end, { buffer = buf })

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        once = true,
        callback = function()
            close(false)
        end,
    })
end

--- Ensure file exists (create empty if needed, including parent dirs)
---@param path string
local function ensure_file_exists(path)
    if vim.fn.filereadable(path) == 1 then
        return
    end
    -- Create parent directories
    local parent = vim.fs.dirname(path)
    if vim.fn.isdirectory(parent) == 0 then
        vim.fn.mkdir(parent, "p")
    end
    -- Create empty file
    fs.create(path, false)
end

--- Confirm save mode selection
---@param bufnr integer
---@param state State
---@param entry Entry?
---@param opts PickerOpts
function M.confirm_save(bufnr, state, entry, opts)
    -- Determine what's selected: marked entry takes priority, then cursor entry
    local marked = state:get_marked_entries()
    local selection = marked[1] or entry

    if not selection then
        vim.notify("sap picker: nothing selected", vim.log.levels.WARN)
        return
    end

    -- Case 1: Directory selected → prompt for filename
    if selection.type == "directory" then
        local save_dir = selection.path
        M.save_input(save_dir, opts.initial_path, function(filename)
            if filename and filename ~= "" then
                local save_path = save_dir .. "/" .. filename
                ensure_file_exists(save_path)
                M.finish({ save_path }, opts, bufnr)
            end
        end)
        return
    end

    -- Case 2: File selected (existing or new entry in buffer)
    local is_existing = selection.id and state:get_by_id(selection.id)
    local is_suggested = selection.id and selection.id == state.suggested_entry_id

    -- Get the intended path from buffer (may differ from state if renamed/moved)
    local intended_path = selection.path
    if selection.id then
        local parser = require("sap.parser")
        local parsed = parser.parse_buffer(bufnr, state.root_path)
        for _, p in ipairs(parsed) do
            if p.id == selection.id then
                intended_path = p.path
                break
            end
        end
    end

    -- Helper to finish with the intended path
    local function do_finish()
        M.finish({ intended_path }, opts, bufnr)
    end

    -- For existing files that were renamed/moved, apply the change
    if is_existing then
        local original_path = state:get_by_id(selection.id).path
        if intended_path ~= original_path then
            -- Apply the rename/move
            local ok, err = fs.move(original_path, intended_path)
            if not ok then
                vim.notify("sap picker: failed to rename: " .. (err or "unknown error"), vim.log.levels.ERROR)
                return
            end
            do_finish()
        elseif not is_suggested then
            -- Same path, different file - confirm overwrite
            confirm_dialog("Overwrite " .. selection.name .. "?", function(confirmed)
                if confirmed then
                    do_finish()
                end
            end)
        else
            do_finish()
        end
    else
        -- New entry - create the file so portal/app can use it
        ensure_file_exists(intended_path)
        do_finish()
    end
end

--- Write output and exit
---@param paths string[]
---@param opts PickerOpts
---@param bufnr integer
function M.finish(paths, opts, bufnr)
    -- Always save to global variable
    vim.g.sap_picker_selection = paths

    -- Write to output file
    if opts.output_file then
        local f = io.open(opts.output_file, "w")
        if f then
            for _, path in ipairs(paths) do
                f:write(path .. "\n")
            end
            f:close()
        else
            vim.notify("sap picker: failed to write output file", vim.log.levels.ERROR)
        end
    end

    -- Save to register if requested
    if opts.register then
        local reg = opts.register == true and "+" or opts.register
        vim.fn.setreg(reg, table.concat(paths, "\n"))
    end

    -- Notify if requested
    if opts.notify then
        vim.notify("Selected: " .. table.concat(paths, ", "), vim.log.levels.INFO)
    end

    -- Call callback if provided
    if opts.callback then
        opts.callback(paths)
    end

    -- Close buffer
    buffer.close(bufnr)

    -- Quit neovim if in portal mode
    if opts.quit_on_confirm then
        vim.cmd("qa!")
    end
end

--- Cancel selection and exit
function M.cancel()
    local bufnr, _, state, _ = get_context()
    if not state or not state.picker_opts then
        return
    end

    local opts = state.picker_opts

    -- Write empty output file
    if opts.output_file then
        local f = io.open(opts.output_file, "w")
        if f then
            f:close()
        end
    end

    -- Call callback with empty list
    if opts.callback then
        opts.callback({})
    end

    -- Close buffer
    buffer.close(bufnr)

    -- Quit neovim if in portal mode
    if opts.quit_on_confirm then
        vim.cmd("qa!")
    end
end

--- Show floating input for save filename
---@param directory string
---@param initial_path string?
---@param callback function(filename: string?)
function M.save_input(directory, initial_path, callback)
    vim.schedule(function()
        local buf = vim.api.nvim_create_buf(false, true)
        local width = 50
        local height = 1

        local win = vim.api.nvim_open_win(buf, true, {
            relative = "editor",
            width = width,
            height = height,
            row = math.floor((vim.o.lines - height) / 2),
            col = math.floor((vim.o.columns - width) / 2),
            style = "minimal",
            border = "rounded",
            title = " Save as ",
            title_pos = "center",
        })

        -- Pre-fill with initial filename if provided
        local initial_name = ""
        if initial_path then
            initial_name = vim.fs.basename(initial_path)
        end
        if initial_name ~= "" then
            vim.api.nvim_buf_set_lines(buf, 0, 1, false, { initial_name })
        end

        vim.bo[buf].buftype = "nofile"
        vim.wo[win].wrap = false

        local closed = false
        local function close_input(result)
            if closed then
                return
            end
            closed = true
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
            end
            callback(result)
        end

        -- Keymaps
        vim.keymap.set({ "n", "i" }, "<CR>", function()
            local filename = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
            close_input(filename)
        end, { buffer = buf })

        vim.keymap.set({ "n", "i" }, "<Esc>", function()
            close_input(nil)
        end, { buffer = buf })

        -- Close on buffer leave
        vim.api.nvim_create_autocmd("BufLeave", {
            buffer = buf,
            once = true,
            callback = function()
                close_input(nil)
            end,
        })

        -- Start in insert mode at end
        vim.cmd("startinsert!")
    end)
end

return M

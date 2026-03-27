local buffer = require("sap.buffer")
local config = require("sap.config")

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

    -- If there are unsaved filesystem changes, apply them first
    if buffer.has_unsaved_changes(bufnr) then
        vim.notify("sap picker: applying filesystem changes first...", vim.log.levels.INFO)
        vim.cmd("write")
        -- User will need to press <CR> again after save completes
        return
    end

    local opts = state.picker_opts
    local marked = state:get_marked_entries()

    -- If nothing marked, use current entry
    if #marked == 0 and entry then
        marked = { entry }
    end

    if #marked == 0 then
        vim.notify("sap picker: nothing selected", vim.log.levels.WARN)
        return
    end

    -- Validate based on mode
    local paths = {}
    for _, e in ipairs(marked) do
        if opts.mode == "open_dir" and e.type ~= "directory" then
            vim.notify("sap picker: must select directories", vim.log.levels.WARN)
            return
        end
        paths[#paths + 1] = e.path
    end

    -- Save mode: if directory selected, prompt for filename
    if opts.mode == "save" and #paths == 1 then
        local e = marked[1]
        if e.type == "directory" then
            M.save_input(e.path, opts.initial_path, function(filename)
                if filename and filename ~= "" then
                    M.finish({ e.path .. "/" .. filename }, opts, bufnr)
                end
            end)
            return
        end
    end

    M.finish(paths, opts, bufnr)
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

local Tree = require("sap.tree")
local fs = require("sap.fs")
local config = require("sap.config")
local has_devicons, devicons = pcall(require, "nvim-web-devicons") -- maybe guard: if config.icons.use_devicons then

local function setup_highlights()
    vim.api.nvim_set_hl(0, "SapDirectory", { link = "Directory", default = true })
    vim.api.nvim_set_hl(0, "SapFile", { link = "Normal", default = true })
    vim.api.nvim_set_hl(0, "SapLink", { link = "Constant", default = true })
    vim.api.nvim_set_hl(0, "SapExecutable", { link = "String", default = true })
    vim.api.nvim_set_hl(0, "SapHidden", { link = "Comment", default = true })
end
setup_highlights()

local M = {}
local ns = vim.api.nvim_create_namespace("sap")

---@class SapState
---@field root Tree
---@field show_hidden boolean?
---@field entries FlatEntry[]?
---@field path_to_id table<string, integer> -- TODO: add a setter that auto generates id and sets
---@field id_to_entry table<integer, FlatEntry>?
---@field next_id integer -- TODO: add getter that auto increments
---@field collapse_cache table<integer, string[]>
---@field parent_cache table<string, {node: Tree, lines: string[], entries: table<integer, FlatEntry>}>

---@type table<integer, SapState>
M.state = {}

---@param path string Absolute directory path
---@return number? bufnr
---@return string? error
M.create = function(path)
    local bufname = "sap:///" .. path
    local bufnr = vim.fn.bufnr(bufname)
    local is_new = bufnr == -1

    -- Create buffer if needed
    if is_new then
        bufnr = vim.api.nvim_create_buf(false, false)
        vim.api.nvim_buf_set_name(bufnr, bufname)
        vim.api.nvim_set_option_value("buftype", "acwrite", { buf = bufnr })
        vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
        vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
        vim.api.nvim_set_option_value("filetype", "sap", { buf = bufnr })
        -- Syntax (buffer-local, set once)
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd([[syntax match sapEntryId "^///\d\+:" conceal]])
        end)
        -- Window options (need to set whenever buffer is displayed)
        vim.api.nvim_create_autocmd("BufWinEnter", {
            buffer = bufnr,
            callback = function()
                vim.wo.conceallevel = 2
                vim.wo.concealcursor = "nvic"
            end,
        })

        vim.api.nvim_create_autocmd("BufWipeout", {
            buffer = bufnr,
            callback = function()
                M.state[bufnr] = nil
            end,
        })
        vim.api.nvim_create_autocmd("BufWriteCmd", {
            buffer = bufnr,
            callback = function()
                M.save(bufnr)
            end,
        })
        vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
            buffer = bufnr,
            callback = function()
                local line = vim.api.nvim_get_current_line()
                local min_col = line:find(":") or 0
                local col = vim.fn.col(".")

                if col <= min_col then
                    vim.api.nvim_win_set_cursor(0, { vim.fn.line("."), min_col })
                end
            end,
        })
    end

    -- Create state if needed
    if not M.state[bufnr] then
        local tree, err = Tree.new(path)
        if not tree then
            return nil, err
        end
        tree.expanded = true
        local ok
        ok, err = tree:sync()
        if not ok then
            return nil, err
        end
        M.state[bufnr] = {
            root = tree,
            show_hidden = false,
            path_to_id = {},
            id_to_entry = {},
            next_id = 1,
            collapse_cache = {},
            parent_cache = {},
        }
    end

    M.render(bufnr)
    return bufnr
end

M.get_or_create_id = function(bufnr, path)
    local state = M.state[bufnr]
    local id = state.path_to_id[path]
    if not id then
        id = state.next_id
        state.next_id = state.next_id + 1
        state.path_to_id[path] = id
    end
    return id
end

---@param node Tree
---@param icons_cfg table
---@return string? icon
---@return string? icon_hl
---@return string name_hl
local function get_icon_and_hl(node, icons_cfg)
    local icon, icon_hl
    local name_hl

    local ftype = node.stat.type
    local is_hidden = node.hidden

    -- Get icon
    if icons_cfg.use_devicons and has_devicons then
        if ftype == "directory" then
            icon, icon_hl = devicons.get_icon(node.name, nil, { default = false })
        else
            local ext = node.name:match("%.(%w+)$")
            icon, icon_hl = devicons.get_icon(node.name, ext, { default = true })
        end
    end
    icon = icon or (ftype == "directory" and icons_cfg.directory or icons_cfg.file)
    icon_hl = icon_hl or (ftype == "directory" and "SapDirectory" or "SapFile")

    -- Determine name highlight (priority: hidden > link > dir > exec > file)
    if is_hidden then
        name_hl = "SapHidden"
    elseif ftype == "link" then
        name_hl = "SapLink"
    elseif ftype == "directory" then
        name_hl = "SapDirectory"
    elseif node:is_exec() then
        name_hl = "SapExecutable"
    else
        name_hl = "SapFile"
    end

    return icon, icon_hl, name_hl
end

---@class ParsedLine
---@field id integer?
---@field indent integer
---@field name string
---@field type "file"|"directory"|"link"
---@field line_num integer

---@param line string
---@return integer? id
---@return integer depth
---@return string name
---@return "file"|"directory"|"link" type
M.parse_line = function(line)
    local id, rest = line:match("^///(%d+):(.*)$")
    local ftype = line:match("/$") and "directory" or "file"
    if not id then
        -- New line (no ID)
        local indent = line:match("^(%s*)") or ""
        local name = line:gsub("^%s*", ""):gsub("/$", "")
        return nil, #indent, name, ftype
    end

    id = tonumber(id)
    local indent = rest:match("^(%s*)") or ""
    local name = rest:gsub("^%s*", ""):gsub("/$", "")
    return id, #indent, name, ftype
end

M.refresh_extmarks = function(bufnr, start_line, end_line)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, start_line, end_line)
    local icons_cfg = config.options.icons
    local state = M.state[bufnr]
    if not state then
        return
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)
    for i, line in ipairs(lines) do
        local id, indent, name, ftype = M.parse_line(line)
        if not id then
            goto continue
        end -- skip new lines without IDs

        local entry = state.id_to_entry[id]
        if not entry then
            goto continue
        end -- skip unknown IDs

        local line_idx = start_line + i - 1 -- 0-indexed
        local prefix_len = #string.format("///%d:", id)
        local col = prefix_len + indent

        local icon, icon_hl, name_hl = get_icon_and_hl(entry.node, icons_cfg)
        local suffix = ftype == "directory" and "/" or ""

        if icon and icon ~= "" then
            vim.api.nvim_buf_set_extmark(bufnr, ns, line_idx, col, {
                virt_text = { { icon .. " ", icon_hl } },
                virt_text_pos = "inline",
            })
        end
        vim.api.nvim_buf_set_extmark(bufnr, ns, line_idx, col, {
            end_col = col + #name + #suffix,
            hl_group = name_hl,
        })

        ::continue::
    end
end

M.refresh_header = function(bufnr)
    local state = M.state[bufnr]
    if not state then
        return
    end
    -- Clear existing header extmarks and add new one
    -- Use a separate namespace for the header so we don't clear icon extmarks
    local header_ns = vim.api.nvim_create_namespace("sap_header")
    vim.api.nvim_buf_clear_namespace(bufnr, header_ns, 0, -1)
    vim.api.nvim_buf_set_extmark(bufnr, header_ns, 0, 0, {
        virt_lines = { { { state.root.path .. "/", "Comment" } } },
        virt_lines_above = true,
    })
end

M.render = function(bufnr)
    local state = M.state[bufnr]
    if not state then
        return
    end
    local entries, err = state.root:flatten()
    if not entries then
        vim.notify("sap: " .. err, vim.log.levels.ERROR)
        return
    end

    state.entries = entries

    -- Draw (skip root itself - it's shown as header extmark)
    local lines = {}
    for _, entry in ipairs(entries) do
        if entry.node.path == state.root.path then
            goto continue  -- root shown as header, not buffer line
        end
        if state.show_hidden or not entry.node.hidden then
            local path = entry.node.path
            local id = M.get_or_create_id(bufnr, path)
            state.id_to_entry[id] = entry
            local indent = string.rep("    ", entry.depth - 1)  -- depth 1 becomes indent 0
            local suffix = entry.node.stat.type == "directory" and "/" or ""
            local prefix = string.format("///%d:", id)
            lines[#lines + 1] = prefix .. indent .. entry.node.name .. suffix
        end
        ::continue::
    end

    -- Write lines to buffer
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    M.refresh_extmarks(bufnr, 0, -1)
    M.refresh_header(bufnr)

    -- Set the buffer to non-modified
    vim.bo[bufnr].modified = false
end

--- Parse buffer and determine intended parent for each line
---@param bufnr integer
---@return ParsedLine[]
local function parse_buffer(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local state = M.state[bufnr]
    local parsed = {}

    -- Recursive helper to parse lines and expand caches
    local function parse_lines(line_list, line_num_offset)
        for i, line in ipairs(line_list) do
            if line ~= "" then
                local id, indent, name, ftype = M.parse_line(line)
                parsed[#parsed + 1] = {
                    id = id,
                    indent = indent,
                    name = name,
                    type = ftype,
                    line_num = line_num_offset + i,
                }

                -- Recursively include cached children (handles nested collapsed dirs)
                if id and state.collapse_cache[id] then
                    local entry = state.id_to_entry[id]
                    if entry and entry.node.stat.type == "directory" and not entry.node.expanded then
                        parse_lines(state.collapse_cache[id], 0) -- line_num not meaningful for cached
                    end
                end
            end
        end
    end

    -- Parse visible buffer lines (and their collapse_cache)
    parse_lines(lines, 0)

    return parsed
end

--- Find parent path for a line based on depth
---@param parsed ParsedLine[]
---@param idx integer
---@param state SapState
---@return string parent_path
local function find_parent_path(parsed, idx, state)
    local my_indent = parsed[idx].indent
    if my_indent == 0 then
        return state.root.path  -- indent 0 = direct child of root
    end
    for i = idx, 1, -1 do
        if parsed[i].indent < my_indent and parsed[i].type == "directory" then
            local id = parsed[i].id
            if id then
                local entry = state.id_to_entry[id]
                if entry then
                    return entry.node.path
                end
            end -- No id, this is a new line
            local grandparent = find_parent_path(parsed, i, state)
            return grandparent .. "/" .. parsed[i].name
        end
    end
    return state.root.path
end

local function format_path(path, ftype)
    return path .. (ftype == "directory" and "/" or "")
end

local function confirm_changes(bufnr, creates, copies, moves, removes)
    local lines = {}
    local is_moving = {}
    for _, c in ipairs(creates) do
        lines[#lines + 1] = "  [ CREATE ] " .. format_path(c.path, c.type)
    end
    for _, cp in ipairs(copies) do
        lines[#lines + 1] = "  [ COPY ] " .. format_path(cp.old_path, cp.type) .. " → " .. format_path(cp.new_path, cp.type)
    end
    for _, m in ipairs(moves) do
        is_moving[m.old_path] = true
        lines[#lines + 1] = "  [ MOVE ] " .. format_path(m.old_path, m.type) .. " → " .. format_path(m.new_path, m.type)
    end
    for _, d in ipairs(removes) do
        -- TODO: dont print cached children of RM
        lines[#lines + 1] = "  [ REMOVE ] " .. format_path(d.path, d.type)
        if d.type == "directory" then
            local children = fs.read_dir(d.path)
            if children then
                local indent = #"  [ REMOVE ] " + 4
                local i = 1
                for _, child in ipairs(children) do
                    if i > 3 then
                        lines[#lines + 1] = string.rep(" ", indent) .. "..."
                        break
                    end
                    if not is_moving[child.path] then
                        lines[#lines + 1] = string.rep(" ", indent) .. child.name .. (child.type == "directory" and "/" or "")
                        i = i + 1
                    end
                end
            end
        end
    end

    if #lines == 0 then
        vim.notify("sap: no changes to apply", vim.log.levels.INFO)
        vim.bo[bufnr].modified = false
        return false
    end

    local msg = "Apply changes?\n" .. table.concat(lines, "\n")
    local choice = vim.fn.confirm(msg, "&Yes\n&No", 2)
    return choice == 1
end

M.save = function(bufnr)
    local state = M.state[bufnr]
    if not state then
        return
    end
    local parsed = parse_buffer(bufnr)

    local seen = {}
    local stays = {} -- Files that have not moved, need to differentiate between move/copy
    local creates = {}
    local moves = {}
    local copies = {}
    local removes = {}

    -- Restore parent_cache entries and mark as seen (they stay in their original location)
    for _, cache in pairs(state.parent_cache) do
        for id, entry in pairs(cache.entries) do
            state.id_to_entry[id] = entry
            seen[id] = true
            stays[id] = true
        end
    end

    -- Populate seen and stays
    for i, line in ipairs(parsed) do
        local intended_path = find_parent_path(parsed, i, state) .. "/" .. parsed[i].name
        local id = line.id
        if id then
            seen[id] = true
            local entry = state.id_to_entry[id]
            if entry then
                local old_path = entry.node.path
                if old_path == intended_path then
                    stays[id] = true
                end
            end
        end
    end

    -- Find Create/Move/Copy
    for i, line in ipairs(parsed) do
        local parent_path = find_parent_path(parsed, i, state)
        local intended_path = parent_path .. "/" .. parsed[i].name
        local id = line.id
        if id then
            local entry = state.id_to_entry[id]
            if entry then
                local old_path = entry.node.path
                if old_path ~= intended_path then
                    if not stays[id] then
                        moves[#moves + 1] = { old_path = old_path, new_path = intended_path, type = line.type }
                        stays[id] = true -- you can only move a file once, rest are copies
                    else
                        copies[#copies + 1] = { old_path = old_path, new_path = intended_path, type = line.type }
                    end
                end
            end
        else -- not id
            creates[#creates + 1] = { path = parent_path .. "/" .. line.name, type = line.type }
        end
    end
    -- Handle new files from parent_cache (they don't have IDs)
    for root_path, cache in pairs(state.parent_cache) do
        for _, line in ipairs(cache.lines) do
            local id, _, name, ftype = M.parse_line(line)
            if not id and name ~= "" then
                -- New file in cached parent - create at cached root path
                creates[#creates + 1] = { path = root_path .. "/" .. name, type = ftype }
            end
        end
    end

    -- Find Delete
    for id, entry in pairs(state.id_to_entry) do
        if not seen[id] then
            removes[#removes + 1] = { path = entry.node.path, type = entry.node.stat.type }
        end
    end

    local confirm = confirm_changes(bufnr, creates, copies, moves, removes)
    if not confirm then
        return
    end

    -- Apply: Create, Copy, Move, Delete (order important)
    for _, c in ipairs(creates) do
        local ok, err = fs.create(c.path, c.type == "directory")
        if not ok then
            vim.notify("sap: create failed: " .. err, vim.log.levels.ERROR)
        end
    end
    for _, cp in ipairs(copies) do
        local ok, err = fs.copy(cp.old_path, cp.new_path)
        if not ok then
            vim.notify("sap: copy failed: " .. err, vim.log.levels.ERROR)
        end
    end
    for _, m in ipairs(moves) do
        local ok, err = fs.move(m.old_path, m.new_path)
        if not ok then
            vim.notify("sap: move failed: " .. err, vim.log.levels.ERROR)
        end
    end
    for _, d in ipairs(removes) do
        local ok, err = fs.remove(d.path)
        if not ok then
            vim.notify("sap: remove failed: " .. err, vim.log.levels.ERROR)
        end
    end

    state.root:sync()
    state.collapse_cache = {}
    state.parent_cache = {}
    -- TODO: maybe clean up stale entries?
    M.render(bufnr)
end

---@param bufnr integer
---@param linenr integer 1-indexed
---@return FlatEntry?
M.get_entry_at_line = function(bufnr, linenr)
    local state = M.state[bufnr]
    if not state then
        return nil
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, linenr - 1, linenr, false)
    if #lines == 0 then
        return nil
    end

    local id = M.parse_line(lines[1])
    if not id then
        return nil
    end

    return state.id_to_entry[id]
end

M.get_path = function(bufnr)
    local state = M.state[bufnr]
    return state and state.root.path
end

M.is_sap_buffer = function(bufnr)
    local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
    return ft == "sap"
end

M.close = function(bufnr)
    -- TODO: check if there are any semantic changes, if set modified = false and close
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local alt = vim.fn.bufnr("#")
    if alt > 0 and alt ~= bufnr and vim.fn.buflisted(alt) == 1 then
        vim.api.nvim_set_current_buf(alt)
    else
        vim.cmd("enew") -- new empty buffer if no alternative
    end
end

return M

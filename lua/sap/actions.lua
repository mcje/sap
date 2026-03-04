local buffer = require("sap.buffer")
local Tree = require("sap.tree")

local M = {}

local _get_context = function()
    local bufnr = vim.api.nvim_get_current_buf()
    local linenr = vim.api.nvim_win_get_cursor(0)[1]
    local state = buffer.state[bufnr]
    local entry = buffer.get_entry_at_line(bufnr, linenr)
    return bufnr, linenr, state, entry
end

--- Adjust collapse_cache indentation for entries under a given path
---@param state SapState
---@param root_path string Path to check entries against
---@param delta integer Number of spaces to add (positive) or remove (negative)
local function adjust_collapse_cache_indent(state, root_path, delta)
    for id, lines in pairs(state.collapse_cache) do
        local cache_entry = state.id_to_entry[id]
        if cache_entry then
            local is_under_root = cache_entry.node.path:sub(1, #root_path) == root_path
            if is_under_root then
                for i, line in ipairs(lines) do
                    local prefix_end = line:find(":") or 0
                    local before = line:sub(1, prefix_end)
                    local after = line:sub(prefix_end + 1)
                    if delta > 0 then
                        lines[i] = before .. string.rep(" ", delta) .. after
                    elseif delta < 0 then
                        local spaces_to_remove = math.min(-delta, #(after:match("^%s*") or ""))
                        lines[i] = before .. after:sub(spaces_to_remove + 1)
                    end
                end
            end
        end
    end
end

local _collapse_dir = function(bufnr, linenr, state, entry)
    if not entry then
        return
    end
    if not entry.node.expanded then
        return -- already collapsed
    end
    if entry.node.stat.type ~= "directory" then
        -- TODO: maybe collapse_parent?
        return -- not a dir
    end
    entry.node.expanded = false

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local dir_line = lines[linenr]

    local id, dir_indent, _, _ = buffer.parse_line(dir_line)
    local delete_start = linenr -- 0 index
    local delete_end = linenr
    for i = linenr + 1, #lines do
        local _, child_indent, _, _ = buffer.parse_line(lines[i])
        if child_indent <= dir_indent then
            break
        end
        delete_end = i
    end

    local removed_lines = vim.api.nvim_buf_get_lines(bufnr, linenr, delete_end, false)
    state.collapse_cache[id] = removed_lines

    if delete_end > linenr then
        vim.api.nvim_buf_set_lines(bufnr, linenr, delete_end, false, {})
    end

    buffer.refresh_extmarks(bufnr, linenr - 1, -1)
end

M.collapse_dir = function()
    local bufnr, linenr, state, entry = _get_context()
    _collapse_dir(bufnr, linenr, state, entry)
end

local _expand_dir = function(bufnr, linenr, state, entry)
    if not entry then
        return
    end
    if entry.node.expanded then
        return -- already expanded
    end
    if entry.node.stat.type ~= "directory" then
        return -- not a dir
    end
    entry.node.expanded = true

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local dir_line = lines[linenr]
    local id, dir_indent, _, _ = buffer.parse_line(dir_line)

    local cached_lines = state.collapse_cache[id]
    if cached_lines then
        vim.api.nvim_buf_set_lines(bufnr, linenr, linenr, false, cached_lines)
        state.collapse_cache[id] = nil
        buffer.refresh_extmarks(bufnr, linenr - 1, linenr + #cached_lines)
    else
        local ok, err = entry.node:sync()
        if not ok then
            vim.notify("sap: couldnt expand " .. entry.node.name .. ": " .. err)
            return
        end
        local child_lines = {}
        local child_paths = vim.tbl_keys(entry.node.children)
        entry.node.sort(child_paths)
        for _, c_path in ipairs(child_paths) do
            local child = entry.node.children[c_path]
            local c_id = buffer.get_or_create_id(bufnr, c_path)
            state.id_to_entry[c_id] = { node = child, depth = entry.depth + 1 }

            local c_indent = string.rep(" ", dir_indent + 4)
            local c_name = child.name
            local c_suffix = child.stat.type == "directory" and "/" or ""
            child_lines[#child_lines + 1] = string.format("///%d:%s%s%s", c_id, c_indent, c_name, c_suffix)
        end
        vim.api.nvim_buf_set_lines(bufnr, linenr, linenr, false, child_lines)
        buffer.refresh_extmarks(bufnr, linenr - 1, linenr + #child_lines)
    end
end

M.expand_dir = function()
    local bufnr, linenr, state, entry = _get_context()
    _expand_dir(bufnr, linenr, state, entry)
end

M.collapse_parent = function()
    -- TODO: implement
end

local _toggle_dir = function(bufnr, linenr, state, entry)
    if not entry or entry.node.stat.type ~= "directory" then
        return
    end

    if entry.node.expanded then
        _collapse_dir(bufnr, linenr, state, entry)
    else
        _expand_dir(bufnr, linenr, state, entry)
    end
end

M.toggle_dir = function()
    local bufnr, linenr, state, entry = _get_context()
    _toggle_dir(bufnr, linenr, state, entry)
end

--- Open file or descend into directory
M.open = function()
    local bufnr, linenr, state, entry = _get_context()
    if not entry then
        return
    end

    if entry.node.stat.type == "directory" then
        _toggle_dir(bufnr, linenr, state, entry)
    else
        -- Open file
        vim.cmd("edit " .. vim.fn.fnameescape(entry.node.path))
    end
end

--- Sets parent as root
M.parent = function()
    local bufnr, _, state, _ = _get_context()

    local root = state.root
    local parent_path = vim.fs.dirname(root.path)

    -- Check if we have a cached parent (from a previous set_root)
    local cached = state.parent_cache[parent_path]
    if cached then
        -- Get current buffer lines (subdir contents, possibly edited)
        local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        -- Indent current lines by 4 (they become children of current root dir)
        local indented_subdir_lines = {}
        for _, line in ipairs(current_lines) do
            if line ~= "" then
                local prefix_end = line:find(":") or 0
                local before = line:sub(1, prefix_end)
                local after = line:sub(prefix_end + 1)
                indented_subdir_lines[#indented_subdir_lines + 1] = before .. "    " .. after
            end
        end

        -- Create entry and line for current root (the subdir becoming a child dir)
        local root_id = buffer.get_or_create_id(bufnr, root.path)
        state.id_to_entry[root_id] = { node = root, depth = 0 }
        local root_line = string.format("///%d:%s/", root_id, root.name)

        -- Restore entries from cache
        for id, entry in pairs(cached.entries) do
            state.id_to_entry[id] = entry
        end

        -- Build path -> lines mapping for sorting
        local path_to_lines = {}
        for _, line in ipairs(cached.lines) do
            local id = buffer.parse_line(line)
            if id then
                local entry = state.id_to_entry[id]
                if entry then
                    path_to_lines[entry.node.path] = { line }
                end
            else
                -- New line without ID - use name as pseudo-path for sorting
                local _, _, name, _ = buffer.parse_line(line)
                path_to_lines[parent_path .. "/" .. name] = { line }
            end
        end
        -- Add current root (now a child dir) with its indented children
        path_to_lines[root.path] = { root_line }
        for _, sl in ipairs(indented_subdir_lines) do
            path_to_lines[root.path][#path_to_lines[root.path] + 1] = sl
        end

        -- Sort paths using the cached parent's sort function
        local paths = vim.tbl_keys(path_to_lines)
        cached.node.sort(paths)

        -- Build combined output
        local combined = {}
        for _, path in ipairs(paths) do
            for _, line in ipairs(path_to_lines[path]) do
                combined[#combined + 1] = line
            end
        end

        -- Update collapse_cache indentation for entries under current root (they're now one level deeper)
        adjust_collapse_cache_indent(state, root.path, 4)

        state.root = cached.node
        state.parent_cache[parent_path] = nil

        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, combined)
        buffer.refresh_extmarks(bufnr, 0, -1)
        buffer.refresh_header(bufnr)
        return
    end

    -- No cache, create fresh parent
    local parent, err = Tree.new(parent_path, root.sort)
    if not parent then
        vim.notify("sap: " .. err, vim.log.levels.ERROR)
        return
    end

    parent.children = {}
    parent.expanded = true
    local ok, sync_err = parent:sync()
    if not ok then
        vim.notify("sap: " .. sync_err, vim.log.levels.ERROR)
        return
    end
    parent.children[root.path] = root -- ensures we keep config for the soon to be child

    -- Update collapse_cache indentation for entries under current root (they're now one level deeper)
    adjust_collapse_cache_indent(state, root.path, 4)

    state.root = parent
    buffer.render(bufnr)
end

M.set_root = function()
    local bufnr, linenr, state, entry = _get_context()
    if not entry then
        return
    end

    local new_root_path = entry.node.path
    -- Cache current buffer lines that are NOT under the new root
    local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local cached_lines = {}
    local cached_entries = {}

    for _, line in ipairs(current_lines) do
        local id, indent, name, ftype = buffer.parse_line(line)
        if id then
            local e = state.id_to_entry[id]
            if e then
                local entry_path = e.node.path
                -- Cache if not under new root (and not the new root itself)
                local is_under_new_root = entry_path:sub(1, #new_root_path) == new_root_path
                if not is_under_new_root then
                    cached_lines[#cached_lines + 1] = line
                    cached_entries[id] = e
                end
            end
        else
            -- New line (no ID) - cache if at root level (indent 0)
            -- These are new files/dirs created in the parent
            if indent == 0 and name ~= "" then
                cached_lines[#cached_lines + 1] = line
            end
        end
    end

    if #cached_lines > 0 then
        state.parent_cache[state.root.path] = {
            node = state.root,
            lines = cached_lines,
            entries = cached_entries,
        }
    end

    local new_root = entry.node
    new_root.expanded = true
    new_root:sync()

    -- Update collapse_cache indentation for entries under new root (one level shallower)
    adjust_collapse_cache_indent(state, new_root_path, -4)

    -- Remove new root from id_to_entry (it's now the header, not an editable entry)
    local new_root_id = state.path_to_id[new_root_path]
    if new_root_id then
        state.id_to_entry[new_root_id] = nil
    end

    state.root = new_root
    buffer.render(bufnr)
end

--- Refresh current directory
M.refresh = function()
    local bufnr, _, state, _ = _get_context()
    state.collapse_cache = {}
    state.parent_cache = {}
    state.root:sync()
    buffer.render(bufnr)
end

--- Toggle hidden files visibility
M.toggle_hidden = function()
    local bufnr, _, state, entry = _get_context()
    state.show_hidden = not state.show_hidden
    buffer.render(bufnr)
end

M.indent = function(visual)
    return function()
        local bufnr, _, _, _ = _get_context()
        local start_line, end_line

        if visual then
            start_line = vim.fn.line("'<")
            end_line = vim.fn.line("'>")
        else
            start_line = vim.fn.line(".")
            end_line = start_line
        end

        for lnum = start_line, end_line do
            local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
            local prefix_end = line:find(":") or 0
            local before = line:sub(1, prefix_end)
            local after = line:sub(prefix_end + 1)
            local new_line = before .. string.rep(" ", vim.bo.shiftwidth) .. after
            vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_line })
        end
    end
end

M.unindent = function(visual)
    return function()
        local bufnr, linenr, _, _ = _get_context()
        local end_line

        if visual then
            linenr = vim.fn.line("'<")
            end_line = vim.fn.line("'>")
        else
            end_line = linenr
        end

        for lnum = linenr, end_line do
            local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
            local prefix_end = line:find(":") or 0
            local before = line:sub(1, prefix_end)
            local after = line:sub(prefix_end + 1)
            local spaces = math.min(vim.bo.shiftwidth, #(after:match("^%s*") or ""))
            local new_line = before .. after:sub(spaces + 1)
            vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_line })
        end
    end
end

return M

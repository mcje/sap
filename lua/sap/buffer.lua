local State = require("sap.state")
local parser = require("sap.parser")
local diff = require("sap.diff")
local render = require("sap.render")
local fs = require("sap.fs")
local config = require("sap.config")
local constants = require("sap.constants")

local M = {}

---@type table<integer, State>
M.states = {}

-- Pending sync timers per buffer (for debouncing)
---@type table<integer, uv_timer_t>
local sync_timers = {}

local SYNC_DEBOUNCE_MS = 150

--- Debounced sync - waits for typing to pause before syncing
---@param bufnr integer
local function debounced_sync(bufnr)
    -- Cancel existing timer for this buffer
    if sync_timers[bufnr] then
        sync_timers[bufnr]:stop()
        sync_timers[bufnr]:close()
        sync_timers[bufnr] = nil
    end

    -- Schedule new sync
    local timer = vim.uv.new_timer()
    sync_timers[bufnr] = timer
    timer:start(SYNC_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
        if sync_timers[bufnr] then
            sync_timers[bufnr]:close()
            sync_timers[bufnr] = nil
        end
        if vim.api.nvim_buf_is_valid(bufnr) and M.states[bufnr] then
            M.sync(bufnr)
        end
    end))
end

render.setup_highlights()
render.setup_decoration_provider(M.states)

local function setup_buffer_options(bufnr, bufname)
    vim.api.nvim_buf_set_name(bufnr, bufname)
    vim.bo[bufnr].buftype = "acwrite"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "sap"

    -- Syntax for concealing ID prefix
    vim.api.nvim_buf_call(bufnr, function()
        vim.cmd(string.format([[syntax match sapEntryId "%s" conceal]], constants.ID_SYNTAX_PATTERN))
    end)
end

local function setup_autocmds(bufnr)
    -- Window options when buffer displayed
    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = bufnr,
        callback = function()
            vim.wo.conceallevel = 2
            vim.wo.concealcursor = "nvic"
        end,
    })

    -- Cleanup on wipe
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = bufnr,
        callback = function()
            M.states[bufnr] = nil
            render.line_info[bufnr] = nil
            if sync_timers[bufnr] then
                sync_timers[bufnr]:stop()
                sync_timers[bufnr]:close()
                sync_timers[bufnr] = nil
            end
        end,
    })

    -- Save handler
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = bufnr,
        callback = function()
            M.save(bufnr)
        end,
    })

    -- Cursor constraint (prevent entering hidden prefix)
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

    -- Sync buffer changes to pending edits (debounced)
    -- Handle both normal mode (TextChanged) and insert mode (TextChangedI)
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = bufnr,
        callback = function()
            debounced_sync(bufnr)
        end,
    })
end

---@param path string
---@return integer? bufnr
---@return string? error
function M.create(path)
    path = vim.fn.fnamemodify(vim.fn.expand(path), ":p"):gsub("/$", "")
    local bufname = constants.BUFFER_SCHEME .. path

    -- Check for existing buffer
    local existing = vim.fn.bufnr(bufname)
    if existing ~= -1 then
        if M.states[existing] then
            -- Reuse existing buffer with state
            vim.api.nvim_set_current_buf(existing)
            return existing
        else
            -- Stale buffer (e.g., after module reload), wipe it
            vim.api.nvim_buf_delete(existing, { force = true })
        end
    end

    -- Create state
    local state = State.new(path, config.options.show_hidden)

    -- Create buffer
    local bufnr = vim.api.nvim_create_buf(false, false)
    M.states[bufnr] = state

    setup_buffer_options(bufnr, bufname)
    setup_autocmds(bufnr)

    render.render(bufnr, state, { clear_undo = true })

    return bufnr
end

---@param bufnr integer
function M.render(bufnr)
    local state = M.states[bufnr]
    if not state then
        return
    end
    render.render(bufnr, state)
end

--- Sync buffer edits to state's pending edits
--- Called on TextChanged to detect deletions, moves, and creates
--- Uses INCREMENTAL approach: only updates pending edits for VISIBLE entries
--- Hidden entries (collapsed, outside root) keep their pending edits unchanged
---@param bufnr integer
function M.sync(bufnr)
    local state = M.states[bufnr]
    if not state then
        return
    end

    local parsed = parser.parse_buffer(bufnr, state.root_path)

    -- Build set of IDs in buffer and their intended paths
    -- Collect ALL occurrences (same ID can appear multiple times for copies)
    local buffer_ids = {}  -- id -> array of parsed entries
    for _, p in ipairs(parsed) do
        if p.id then
            if not buffer_ids[p.id] then
                buffer_ids[p.id] = {}
            end
            table.insert(buffer_ids[p.id], p)
        end
    end

    -- INCREMENTAL SYNC: Only update pending edits for visible entries
    -- Hidden entries keep their existing pending edits untouched

    -- Process each entry in state
    for id, entry in pairs(state.entries) do
        -- Skip hidden entries - don't touch their pending edits
        if state:is_intentionally_hidden(entry) then
            goto continue
        end

        -- Skip entries with pending move to a hidden destination
        -- (e.g., moved to a collapsed directory - we can't see it in buffer)
        local pending_dest = state.pending_moves[entry.path]
        if pending_dest then
            local dest_hidden = state:is_intentionally_hidden({
                path = pending_dest,
                hidden = vim.fs.basename(pending_dest):sub(1, 1) == ".",
            })
            if dest_hidden then
                goto continue
            end
        end

        local parsed_entries = buffer_ids[id] or {}

        if #parsed_entries == 0 then
            -- Entry not in buffer -> check if there's a pending copy that should become a move
            local dominated_by_copy = nil
            for path, create in pairs(state.pending_creates) do
                if create.copy_of == entry.path then
                    dominated_by_copy = path
                    break
                end
            end

            if dominated_by_copy then
                -- Copy becomes a move (original is now gone)
                state.pending_creates[dominated_by_copy] = nil
                state.pending_moves[entry.path] = dominated_by_copy
                state.pending_deletes[entry.path] = nil
            else
                -- Plain delete
                state.pending_moves[entry.path] = nil
                state.pending_deletes[entry.path] = true
            end
        else
            -- Check if original path is among the occurrences
            local has_original = false
            local copy_paths = {}
            for _, pe in ipairs(parsed_entries) do
                if pe.path == entry.path then
                    has_original = true
                else
                    table.insert(copy_paths, { path = pe.path, type = entry.type })
                end
            end

            if has_original then
                -- Original still in buffer -> no move/delete
                state.pending_deletes[entry.path] = nil
                state.pending_moves[entry.path] = nil
                -- Extra occurrences are copies -> track as pending creates with copy source
                -- (so they survive render() and diff.calculate knows they're copies)
                for _, copy in ipairs(copy_paths) do
                    state:mark_copy(entry.path, copy.path, copy.type)
                end
            elseif #copy_paths > 0 then
                -- Original not in buffer, but ID appears elsewhere -> move to first
                state.pending_deletes[entry.path] = nil
                state.pending_moves[entry.path] = copy_paths[1].path
                -- Clear any pending copy - it's now a move since original is gone
                state.pending_creates[copy_paths[1].path] = nil
                -- Additional occurrences beyond the first are copies of the move destination
                for i = 2, #copy_paths do
                    state:mark_copy(copy_paths[1].path, copy_paths[i].path, copy_paths[i].type)
                end
            end
        end

        ::continue::
    end

    -- Handle pending creates for visible paths
    -- Remove creates that are visible but no longer in buffer
    for path, _ in pairs(state.pending_creates) do
        local fake_entry = {
            path = path,
            hidden = vim.fs.basename(path):sub(1, 1) == ".",
        }
        if not state:is_intentionally_hidden(fake_entry) then
            -- This create path is visible - check if still in buffer
            -- Check for ANY line at this path (with or without ID - copies have IDs)
            local found = false
            for _, p in ipairs(parsed) do
                if p.path == path then
                    found = true
                    break
                end
            end
            if not found then
                state.pending_creates[path] = nil
            end
        end
    end

    -- Check for new entries (lines without IDs)
    for _, p in ipairs(parsed) do
        if not p.id then
            -- New entry (no ID) -> create
            state:mark_create(p.path, p.type)
        end
    end

    -- Update line_info for guides based on current buffer structure
    render.update_line_info_from_parsed(bufnr, parsed, state)

    -- Force full redraw to update guide decorations
    vim.cmd("redraw!")
end

local function format_path(path, ftype)
    return path .. (ftype == "directory" and "/" or "")
end

local function confirm_changes(changes)
    local lines = {}

    for _, c in ipairs(changes.creates) do
        lines[#lines + 1] = "  [CREATE] " .. format_path(c.path, c.type)
    end
    for _, c in ipairs(changes.copies) do
        lines[#lines + 1] = "  [COPY] " .. format_path(c.from, c.type) .. " -> " .. format_path(c.to, c.type)
    end
    for _, m in ipairs(changes.moves) do
        lines[#lines + 1] = "  [MOVE] " .. format_path(m.from, m.type) .. " -> " .. format_path(m.to, m.type)
    end
    for _, d in ipairs(changes.deletes) do
        lines[#lines + 1] = "  [DELETE] " .. format_path(d.path, d.type)
    end

    if #lines == 0 then
        return false
    end

    local msg = "Apply changes?\n" .. table.concat(lines, "\n")
    local choice = vim.fn.confirm(msg, "&Yes\n&No", 2)
    return choice == 1
end

local function apply_changes(changes)
    local errors = {}

    -- Order: create -> copy -> move -> delete
    for _, c in ipairs(changes.creates) do
        local ok, err = fs.create(c.path, c.type == "directory")
        if not ok then
            errors[#errors + 1] = "create " .. c.path .. ": " .. err
        end
    end

    for _, c in ipairs(changes.copies) do
        local ok, err = fs.copy(c.from, c.to)
        if not ok then
            errors[#errors + 1] = "copy " .. c.from .. ": " .. err
        end
    end

    for _, m in ipairs(changes.moves) do
        local ok, err = fs.move(m.from, m.to)
        if not ok then
            errors[#errors + 1] = "move " .. m.from .. ": " .. err
        end
    end

    for _, d in ipairs(changes.deletes) do
        local ok, err = fs.remove(d.path)
        if not ok then
            errors[#errors + 1] = "delete " .. d.path .. ": " .. err
        end
    end

    return errors
end

--- Convert hidden content to ParsedEntry format for diff calculation
---@param hidden HiddenEntry[]
---@return ParsedEntry[]
local function hidden_to_parsed(hidden)
    local result = {}
    for _, h in ipairs(hidden) do
        result[#result + 1] = {
            id = h.id,
            path = h.path,
            name = h.name,
            type = h.type,
            indent = 0,  -- Not used for diff
            linenr = 0,  -- Not in visible buffer
        }
    end
    return result
end

---@param bufnr integer
function M.save(bufnr)
    local state = M.states[bufnr]
    if not state then
        return
    end

    -- Sync immediately to ensure pending state is up to date
    -- (debounced sync might not have run yet)
    M.sync(bufnr)

    -- Get visible entries from buffer
    local parsed = parser.parse_buffer(bufnr, state.root_path)

    -- Add hidden entries (collapsed directories, etc.)
    local hidden = state:get_all_hidden_content()
    local hidden_parsed = hidden_to_parsed(hidden)
    for _, hp in ipairs(hidden_parsed) do
        parsed[#parsed + 1] = hp
    end

    local changes = diff.calculate(state, parsed)

    if diff.is_empty(changes) then
        vim.notify("sap: no changes", vim.log.levels.INFO)
        vim.bo[bufnr].modified = false
        return
    end

    if not confirm_changes(changes) then
        return
    end

    local errors = apply_changes(changes)

    if #errors > 0 then
        for _, e in ipairs(errors) do
            vim.notify("sap: " .. e, vim.log.levels.ERROR)
        end
    end

    -- Refresh state and re-render
    state:refresh()
    render.render(bufnr, state, { clear_undo = true })
end

---@param bufnr integer
---@return State?
function M.get_state(bufnr)
    return M.states[bufnr]
end

---@param bufnr integer
---@param linenr integer (1-indexed)
---@return Entry|ParsedEntry|nil
function M.get_entry_at_line(bufnr, linenr)
    local state = M.states[bufnr]
    if not state then
        return nil
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, linenr - 1, linenr, false)
    if #lines == 0 then
        return nil
    end

    local id = parser.parse_line(lines[1])
    if id then
        return state:get_by_id(id)
    end

    -- No ID - parse buffer to compute path for new entries
    local parsed = parser.parse_buffer(bufnr, state.root_path)
    for _, p in ipairs(parsed) do
        if p.linenr == linenr then
            -- Populate Entry-compatible fields
            p.parent_path = vim.fs.dirname(p.path)
            p.hidden = p.name:sub(1, 1) == "."
            return p
        end
    end
    return nil
end

function M.close(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local alt = vim.fn.bufnr("#")
    if alt > 0 and alt ~= bufnr and vim.fn.buflisted(alt) == 1 then
        vim.api.nvim_set_current_buf(alt)
    else
        vim.cmd("enew")
    end
end

--- Clear undo history for buffer (prevents undoing past structural changes)
---@param bufnr integer
function M.clear_undo(bufnr)
    local old_undolevels = vim.bo[bufnr].undolevels
    vim.bo[bufnr].undolevels = -1
    -- Make a no-op change to create undo break
    local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { line })
    vim.bo[bufnr].undolevels = old_undolevels
end

return M

local M = {}

---@class Changes
---@field creates {path: string, type: string}[]
---@field moves {from: string, to: string, type: string}[]
---@field copies {from: string, to: string, type: string}[]
---@field deletes {path: string, type: string}[]

--- Calculate diff between current state and parsed buffer
---@param state State
---@param parsed ParsedEntry[]
---@return Changes
function M.calculate(state, parsed)
    local creates = {}
    local moves = {}
    local copies = {}
    local deletes = {}

    local seen_ids = {}       -- ids that appear in buffer
    local staying = {}        -- paths that aren't moving (same id, same path)

    -- First pass: find entries that are staying in place
    for _, p in ipairs(parsed) do
        if p.id then
            local entry = state:get_by_id(p.id)
            if entry and entry.path == p.path then
                staying[entry.path] = true
            end
        end
    end

    -- Second pass: categorize all entries
    for _, p in ipairs(parsed) do
        if not p.id then
            -- No id = new entry = create (unless it's a tracked copy or move destination)
            local pending = state.pending_creates[p.path]
            if pending and pending.copy_of then
                -- It's a copy tracked in pending_creates, will be handled later
                -- Skip adding to creates
            else
                -- Check if this is a move destination
                local is_move_dest = false
                for _, to_path in pairs(state.pending_moves) do
                    if to_path == p.path then
                        is_move_dest = true
                        break
                    end
                end
                if not is_move_dest then
                    creates[#creates + 1] = {
                        path = p.path,
                        type = p.type,
                    }
                end
            end
        else
            seen_ids[p.id] = true
            local entry = state:get_by_id(p.id)

            if entry then
                local original_path = entry.path
                local intended_path = p.path

                if original_path ~= intended_path then
                    -- Path changed
                    if not staying[original_path] then
                        -- Original location is empty = move
                        moves[#moves + 1] = {
                            from = original_path,
                            to = intended_path,
                            type = p.type,
                        }
                        staying[original_path] = true  -- can only move once
                    else
                        -- Original still exists = copy
                        copies[#copies + 1] = {
                            from = original_path,
                            to = intended_path,
                            type = p.type,
                        }
                    end
                end
                -- else: same path = no change
            end
        end
    end

    -- Third pass: find deletes (entries not in buffer, not intentionally hidden)
    for id, entry in pairs(state.entries) do
        if not seen_ids[id] and not staying[entry.path] then
            -- Only mark as delete if not intentionally hidden (collapsed/hidden)
            -- and not already tracked as a move
            if not state:is_intentionally_hidden(entry) and not state.pending_moves[entry.path] then
                deletes[#deletes + 1] = {
                    path = entry.path,
                    type = entry.type,
                }
            end
        end
    end

    -- Fourth pass: include pending_deletes (user deletions preserved across navigation)
    for path, _ in pairs(state.pending_deletes) do
        -- Avoid duplicates
        local already_added = false
        for _, d in ipairs(deletes) do
            if d.path == path then
                already_added = true
                break
            end
        end
        if not already_added then
            local entry = state:get_by_path(path)
            if entry then
                deletes[#deletes + 1] = {
                    path = entry.path,
                    type = entry.type,
                }
            end
        end
    end

    -- Also include pending_moves and pending_creates
    for from_path, to_path in pairs(state.pending_moves) do
        -- Skip if this is actually a copy (original still exists at source)
        local dominated_by_copy = false
        local pending_create = state.pending_creates[to_path]
        if pending_create and pending_create.copy_of == from_path then
            dominated_by_copy = true
        end

        if not dominated_by_copy then
            local already_added = false
            for _, m in ipairs(moves) do
                if m.from == from_path then
                    already_added = true
                    break
                end
            end
            if not already_added then
                local entry = state:get_by_path(from_path)
                if entry then
                    moves[#moves + 1] = {
                        from = from_path,
                        to = to_path,
                        type = entry.type,
                    }
                end
            end
        end
    end

    for path, create in pairs(state.pending_creates) do
        if create.copy_of then
            -- It's a copy, not a plain create
            -- Check not already in copies
            local already_in_copies = false
            for _, c in ipairs(copies) do
                if c.to == path then
                    already_in_copies = true
                    break
                end
            end
            -- Also remove from moves if present (copy takes precedence when original exists)
            local move_idx = nil
            for i, m in ipairs(moves) do
                if m.from == create.copy_of and m.to == path then
                    move_idx = i
                    break
                end
            end
            if move_idx then
                table.remove(moves, move_idx)
            end
            if not already_in_copies then
                copies[#copies + 1] = {
                    from = create.copy_of,
                    to = path,
                    type = create.type,
                }
            end
        else
            -- Regular create
            local already_added = false
            for _, c in ipairs(creates) do
                if c.path == path then
                    already_added = true
                    break
                end
            end
            if not already_added then
                creates[#creates + 1] = {
                    path = path,
                    type = create.type,
                }
            end
        end
    end

    return {
        creates = creates,
        moves = moves,
        copies = copies,
        deletes = deletes,
    }
end

---@param changes Changes
---@return boolean
function M.is_empty(changes)
    return #changes.creates == 0
        and #changes.moves == 0
        and #changes.copies == 0
        and #changes.deletes == 0
end

return M

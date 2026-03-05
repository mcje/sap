-- Tests for buffer sync logic and is_intentionally_hidden
-- Run with: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/sap/sync_spec.lua"

describe("sap.buffer sync", function()
    local State = require("sap.state")
    local test_dir

    local function setup_test_dir()
        local tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        vim.fn.mkdir(tmp .. "/child", "p")
        vim.fn.mkdir(tmp .. "/sibling", "p")
        vim.fn.writefile({}, tmp .. "/file.txt")
        vim.fn.writefile({}, tmp .. "/child/nested.txt")
        vim.fn.writefile({}, tmp .. "/.hidden")
        return tmp
    end

    local function cleanup_test_dir(dir)
        vim.fn.delete(dir, "rf")
    end

    before_each(function()
        test_dir = setup_test_dir()
    end)

    after_each(function()
        if test_dir then
            cleanup_test_dir(test_dir)
        end
    end)

    describe("is_intentionally_hidden", function()
        it("should return false for root entry", function()
            local state = State.new(test_dir)
            local root = state:get_by_path(test_dir)
            assert.is_false(state:is_intentionally_hidden(root))
        end)

        it("should return false for direct children of root", function()
            local state = State.new(test_dir)
            local child = state:get_by_path(test_dir .. "/child")
            assert.is_false(state:is_intentionally_hidden(child))
        end)

        it("should return true for entries outside root", function()
            -- Start in child, then check if parent is "intentionally hidden"
            local state = State.new(test_dir .. "/child")
            -- Add parent to state (simulating what go_to_parent would do)
            state:add_entry(test_dir, nil)

            local parent_entry = state:get_by_path(test_dir)
            assert.is_true(state:is_intentionally_hidden(parent_entry))
        end)

        it("should return true for siblings when root is child dir", function()
            local state = State.new(test_dir)
            -- Navigate to child
            local child = state:get_by_path(test_dir .. "/child")
            state:set_root(child)

            -- sibling should now be "intentionally hidden" because it's not under child
            local sibling = state:get_by_path(test_dir .. "/sibling")
            if sibling then
                assert.is_true(state:is_intentionally_hidden(sibling))
            end
        end)

        it("should return true for entries under collapsed directory", function()
            local state = State.new(test_dir)
            local child = state:get_by_path(test_dir .. "/child")
            state:expand(child) -- Load children
            state:collapse(child) -- Then collapse

            local nested = state:get_by_path(test_dir .. "/child/nested.txt")
            if nested then
                assert.is_true(state:is_intentionally_hidden(nested))
            end
        end)

        it("should return true for hidden files when show_hidden is false", function()
            local state = State.new(test_dir, false) -- show_hidden = false
            local hidden = state:get_by_path(test_dir .. "/.hidden")
            if hidden then
                assert.is_true(state:is_intentionally_hidden(hidden))
            end
        end)

        it("should return false for hidden files when show_hidden is true", function()
            local state = State.new(test_dir, true) -- show_hidden = true
            local hidden = state:get_by_path(test_dir .. "/.hidden")
            assert.is_not_nil(hidden)
            assert.is_false(state:is_intentionally_hidden(hidden))
        end)
    end)

    describe("navigation with sync simulation", function()
        -- Simulates what sync() does
        local function simulate_sync(state, visible_ids)
            state:clear_pending()

            for id, entry in pairs(state.entries) do
                if not visible_ids[id] then
                    if not state:is_intentionally_hidden(entry) then
                        state:mark_delete(entry.path)
                    end
                end
            end
        end

        it("should not mark siblings as deleted after set_root", function()
            local state = State.new(test_dir)

            -- Get all visible IDs initially
            local children = state:get_children(test_dir)
            local root = state:get_by_path(test_dir)

            -- Simulate buffer showing root + children
            local visible_ids = { [root.id] = true }
            for _, c in ipairs(children) do
                if c.id then visible_ids[c.id] = true end
            end

            -- Navigate to child
            local child = state:get_by_path(test_dir .. "/child")
            state:expand(child)
            state:set_root(child)

            -- After set_root, only child and its children are visible
            local new_visible_ids = { [child.id] = true }
            for _, c in ipairs(state:get_children(state.root_path)) do
                if c.id then new_visible_ids[c.id] = true end
            end

            -- Simulate sync with new visible IDs
            simulate_sync(state, new_visible_ids)

            -- Parent and siblings should NOT be in pending_deletes
            -- because they're "intentionally hidden" (outside root)
            assert.is_false(state:is_deleted(test_dir))
            assert.is_false(state:is_deleted(test_dir .. "/sibling"))
            assert.is_false(state:is_deleted(test_dir .. "/file.txt"))
        end)

        it("should preserve siblings after parent -> child -> parent", function()
            -- Start in child
            local state = State.new(test_dir .. "/child")

            -- Go to parent
            state:go_to_parent()
            assert.equals(test_dir, state.root_path)

            -- Capture visible entries at parent level
            local root = state:get_by_path(test_dir)
            local visible_ids = { [root.id] = true }
            for _, c in ipairs(state:get_children(test_dir)) do
                if c.id then visible_ids[c.id] = true end
            end

            -- Count children
            local count_at_parent = #state:get_children(test_dir)

            -- Go back to child (set_root)
            local child = state:get_by_path(test_dir .. "/child")
            state:set_root(child)

            -- Simulate sync - only child and its descendants are visible
            local child_visible_ids = { [child.id] = true }
            for _, c in ipairs(state:get_children(state.root_path)) do
                if c.id then child_visible_ids[c.id] = true end
            end
            simulate_sync(state, child_visible_ids)

            -- Siblings should NOT be deleted (they're outside root)
            assert.is_false(state:is_deleted(test_dir .. "/sibling"))

            -- Go back to parent
            state:go_to_parent()
            assert.equals(test_dir, state.root_path)

            -- Siblings should still be there
            local count_back_at_parent = #state:get_children(test_dir)
            assert.equals(count_at_parent, count_back_at_parent)
        end)

        it("should actually delete entries that user removed", function()
            local state = State.new(test_dir)

            local root = state:get_by_path(test_dir)
            local children = state:get_children(test_dir)

            -- Simulate buffer showing root + all children except file.txt (user deleted it)
            local visible_ids = { [root.id] = true }
            for _, c in ipairs(children) do
                if c.id and c.name ~= "file.txt" then
                    visible_ids[c.id] = true
                end
            end

            simulate_sync(state, visible_ids)

            -- file.txt SHOULD be deleted (it's visible at root level but not in buffer)
            assert.is_true(state:is_deleted(test_dir .. "/file.txt"))
        end)

        it("should preserve deletions when navigating to child", function()
            -- This is the key bug scenario:
            -- 1. Go to parent, delete file
            -- 2. Go to child (set_root)
            -- 3. Go back to parent - deleted file should still be deleted

            local state = State.new(test_dir)

            -- User deletes file.txt
            state:mark_delete(test_dir .. "/file.txt")
            assert.is_true(state:is_deleted(test_dir .. "/file.txt"))

            -- Navigate to child
            local child = state:get_by_path(test_dir .. "/child")
            state:set_root(child)

            -- file.txt is now "intentionally hidden" (outside root)
            -- A proper sync should PRESERVE the deletion

            -- Simulate sync with only child entries visible
            local child_visible_ids = { [child.id] = true }
            for _, c in ipairs(state:get_children(state.root_path)) do
                if c.id then child_visible_ids[c.id] = true end
            end

            -- This is the NEW sync behavior: preserve pending edits for hidden entries
            local old_deletes = vim.tbl_extend("force", {}, state.pending_deletes)
            state:clear_pending()

            -- Restore deletes for entries outside root
            for path, _ in pairs(old_deletes) do
                local entry = state:get_by_path(path)
                if entry and state:is_intentionally_hidden(entry) then
                    state.pending_deletes[path] = true
                end
            end

            -- file.txt deletion should be preserved
            assert.is_true(state:is_deleted(test_dir .. "/file.txt"))

            -- Navigate back to parent
            state:go_to_parent()

            -- file.txt should still be deleted
            assert.is_true(state:is_deleted(test_dir .. "/file.txt"))

            -- And get_children should NOT include it
            local children = state:get_children(test_dir)
            local has_file = false
            for _, c in ipairs(children) do
                if c.name == "file.txt" then has_file = true end
            end
            assert.is_false(has_file, "deleted file should not appear after navigation")
        end)
    end)

    describe("expand/collapse with pending edits", function()
        local buffer = require("sap.buffer")
        local parser = require("sap.parser")

        -- Helper to simulate what buffer.sync does (INCREMENTAL approach)
        local function full_sync(state, parsed)
            -- Collect ALL occurrences of each ID (for copy detection)
            local buffer_ids = {}
            for _, p in ipairs(parsed) do
                if p.id then
                    if not buffer_ids[p.id] then
                        buffer_ids[p.id] = {}
                    end
                    table.insert(buffer_ids[p.id], p)
                end
            end

            -- INCREMENTAL: only update pending edits for visible entries
            for id, entry in pairs(state.entries) do
                -- Skip hidden entries
                if state:is_intentionally_hidden(entry) then
                    goto continue
                end

                -- Skip entries with pending move to hidden destination
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
                    -- Check if there's a pending copy that should become a move
                    local dominated_by_copy = nil
                    for path, create in pairs(state.pending_creates) do
                        if create.copy_of == entry.path then
                            dominated_by_copy = path
                            break
                        end
                    end

                    if dominated_by_copy then
                        state.pending_creates[dominated_by_copy] = nil
                        state.pending_moves[entry.path] = dominated_by_copy
                        state.pending_deletes[entry.path] = nil
                    else
                        state.pending_moves[entry.path] = nil
                        state.pending_deletes[entry.path] = true
                    end
                else
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
                        state.pending_deletes[entry.path] = nil
                        state.pending_moves[entry.path] = nil
                        for _, copy in ipairs(copy_paths) do
                            state:mark_copy(entry.path, copy.path, copy.type)
                        end
                    elseif #copy_paths > 0 then
                        state.pending_deletes[entry.path] = nil
                        state.pending_moves[entry.path] = copy_paths[1].path
                        state.pending_creates[copy_paths[1].path] = nil
                        for i = 2, #copy_paths do
                            state:mark_copy(copy_paths[1].path, copy_paths[i].path, copy_paths[i].type)
                        end
                    end
                end

                ::continue::
            end

            -- Handle creates for visible paths
            for path, _ in pairs(state.pending_creates) do
                local fake_entry = {
                    path = path,
                    hidden = vim.fs.basename(path):sub(1, 1) == ".",
                }
                if not state:is_intentionally_hidden(fake_entry) then
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

            for _, p in ipairs(parsed) do
                if not p.id then
                    state:mark_create(p.path, p.type)
                end
            end
        end

        it("should preserve pending creates when collapsing parent directory", function()
            local state = State.new(test_dir)

            -- Expand child directory
            local child = state:get_by_path(test_dir .. "/child")
            state:expand(child)

            -- User creates a new file inside child (no ID means new file)
            local new_file_path = test_dir .. "/child/newfile.txt"
            state:mark_create(new_file_path, "file")
            assert.is_not_nil(state.pending_creates[new_file_path])

            -- Simulate buffer state before collapse (child is expanded, newfile visible)
            local parsed_before = {}
            local root = state:get_by_path(test_dir)
            parsed_before[#parsed_before + 1] = { id = root.id, path = root.path, type = "directory" }
            for _, c in ipairs(state:get_children(test_dir)) do
                parsed_before[#parsed_before + 1] = { id = c.id, path = c.path, type = c.type }
            end
            for _, c in ipairs(state:get_children(test_dir .. "/child")) do
                parsed_before[#parsed_before + 1] = { id = c.id, path = c.path, type = c.type }
            end
            -- Add the new file (no ID)
            parsed_before[#parsed_before + 1] = { id = nil, path = new_file_path, type = "file" }

            -- Sync before collapse (this captures the create)
            full_sync(state, parsed_before)
            assert.is_not_nil(state.pending_creates[new_file_path], "create should exist after first sync")

            -- Collapse the child directory
            state:collapse(child)

            -- After collapse, simulate buffer showing only root level
            local parsed_after = {}
            parsed_after[#parsed_after + 1] = { id = root.id, path = root.path, type = "directory" }
            for _, c in ipairs(state:get_children(test_dir)) do
                parsed_after[#parsed_after + 1] = { id = c.id, path = c.path, type = c.type }
            end

            -- Sync after collapse
            full_sync(state, parsed_after)

            -- The pending create should be preserved (it's under collapsed directory)
            assert.is_not_nil(state.pending_creates[new_file_path],
                "pending create should be preserved after collapse")
        end)

        it("should preserve pending creates through expand-collapse-expand cycle", function()
            local state = State.new(test_dir)

            -- Expand child directory
            local child = state:get_by_path(test_dir .. "/child")
            state:expand(child)

            -- User creates a new file
            local new_file_path = test_dir .. "/child/newfile.txt"
            state:mark_create(new_file_path, "file")

            -- Build parsed with the new file
            local function build_parsed_expanded()
                local parsed = {}
                local root = state:get_by_path(test_dir)
                parsed[#parsed + 1] = { id = root.id, path = root.path, type = "directory" }
                for _, c in ipairs(state:get_children(test_dir)) do
                    parsed[#parsed + 1] = { id = c.id, path = c.path, type = c.type }
                    if c.path == test_dir .. "/child" and state:is_expanded(c) then
                        for _, gc in ipairs(state:get_children(c.path)) do
                            parsed[#parsed + 1] = { id = gc.id, path = gc.path, type = gc.type }
                        end
                        -- Add new file (no ID)
                        parsed[#parsed + 1] = { id = nil, path = new_file_path, type = "file" }
                    end
                end
                return parsed
            end

            local function build_parsed_collapsed()
                local parsed = {}
                local root = state:get_by_path(test_dir)
                parsed[#parsed + 1] = { id = root.id, path = root.path, type = "directory" }
                for _, c in ipairs(state:get_children(test_dir)) do
                    parsed[#parsed + 1] = { id = c.id, path = c.path, type = c.type }
                end
                return parsed
            end

            -- Sync while expanded
            full_sync(state, build_parsed_expanded())
            assert.is_not_nil(state.pending_creates[new_file_path])

            -- Collapse
            state:collapse(child)
            full_sync(state, build_parsed_collapsed())
            assert.is_not_nil(state.pending_creates[new_file_path], "should preserve after collapse")

            -- Expand again
            state:expand(child)
            full_sync(state, build_parsed_expanded())
            assert.is_not_nil(state.pending_creates[new_file_path], "should preserve after re-expand")

            -- Collapse again
            state:collapse(child)
            full_sync(state, build_parsed_collapsed())
            assert.is_not_nil(state.pending_creates[new_file_path], "should preserve after second collapse")
        end)

        it("should NOT preserve creates that are explicitly removed by user", function()
            local state = State.new(test_dir)

            local child = state:get_by_path(test_dir .. "/child")
            state:expand(child)

            -- Verify child is expanded (important for is_intentionally_hidden check)
            assert.is_true(state:is_expanded(child), "child should be expanded")

            -- User creates a new file
            local new_file_path = test_dir .. "/child/newfile.txt"

            -- Build parsed WITH the new file (simulating user adding a line with no ID)
            local root = state:get_by_path(test_dir)
            local parsed_with = {}
            parsed_with[#parsed_with + 1] = { id = root.id, path = root.path, type = "directory" }
            for _, c in ipairs(state:get_children(test_dir)) do
                parsed_with[#parsed_with + 1] = { id = c.id, path = c.path, type = c.type }
                if c.path == test_dir .. "/child" then
                    for _, gc in ipairs(state:get_children(c.path)) do
                        parsed_with[#parsed_with + 1] = { id = gc.id, path = gc.path, type = gc.type }
                    end
                    -- Add the new file (no ID = new create)
                    parsed_with[#parsed_with + 1] = { id = nil, path = new_file_path, type = "file" }
                end
            end

            full_sync(state, parsed_with)
            assert.is_not_nil(state.pending_creates[new_file_path], "create should exist after first sync")

            -- Verify the new file would NOT be considered hidden (child is expanded)
            local fake_entry = { path = new_file_path, hidden = false }
            assert.is_false(state:is_intentionally_hidden(fake_entry),
                "new file should NOT be hidden when parent is expanded")

            -- User deletes the line (removes the create) - parsed WITHOUT the new file
            -- Note: get_children includes pending creates, so we filter to only entries with IDs
            local parsed_without = {}
            parsed_without[#parsed_without + 1] = { id = root.id, path = root.path, type = "directory" }
            for _, c in ipairs(state:get_children(test_dir)) do
                if c.id then  -- Only include actual entries (not pending creates)
                    parsed_without[#parsed_without + 1] = { id = c.id, path = c.path, type = c.type }
                    if c.path == test_dir .. "/child" then
                        for _, gc in ipairs(state:get_children(c.path)) do
                            if gc.id then  -- Only include actual entries
                                parsed_without[#parsed_without + 1] = { id = gc.id, path = gc.path, type = gc.type }
                            end
                        end
                    end
                end
            end

            -- Before calling full_sync, verify create exists
            assert.is_not_nil(state.pending_creates[new_file_path], "create should exist before second sync")

            -- Check is_intentionally_hidden BEFORE full_sync
            local fake_before = { path = new_file_path, hidden = false }
            local hidden_before = state:is_intentionally_hidden(fake_before)
            assert.is_false(hidden_before, "create should NOT be hidden before sync (child is expanded)")

            full_sync(state, parsed_without)

            -- Create should be GONE because:
            -- 1. It was NOT restored (parent was expanded, so not hidden)
            -- 2. It was NOT re-detected (line was deleted from buffer)
            assert.is_nil(state.pending_creates[new_file_path],
                "create should be removed when user deletes the line")
        end)

        it("should preserve pending moves when collapsing DESTINATION directory", function()
            -- BUG: Moving file from A/ to B/, then collapsing B/ loses the pending move
            -- because sync only checks if the SOURCE is hidden, not the DESTINATION
            local state = State.new(test_dir)

            -- Expand both child and sibling directories
            local child = state:get_by_path(test_dir .. "/child")
            local sibling = state:get_by_path(test_dir .. "/sibling")
            state:expand(child)
            state:expand(sibling)

            -- Get nested.txt from child
            local nested = state:get_by_path(test_dir .. "/child/nested.txt")
            assert.is_not_nil(nested, "nested.txt should exist")

            -- User moves nested.txt from child/ to sibling/
            local from_path = test_dir .. "/child/nested.txt"
            local to_path = test_dir .. "/sibling/nested.txt"
            state:mark_move(from_path, to_path)
            assert.equals(to_path, state.pending_moves[from_path])

            -- Build parsed state before collapse (both dirs expanded, file appears in sibling)
            local function build_parsed_both_expanded()
                local parsed = {}
                local root = state:get_by_path(test_dir)
                parsed[#parsed + 1] = { id = root.id, path = root.path, type = "directory" }
                for _, c in ipairs(state:get_children(test_dir)) do
                    if c.id then
                        -- For the moved file, use its ID but show it in new location
                        if c.id == nested.id then
                            parsed[#parsed + 1] = { id = c.id, path = to_path, type = c.type }
                        else
                            parsed[#parsed + 1] = { id = c.id, path = c.path, type = c.type }
                        end
                    end
                    if c.type == "directory" and state:is_expanded(c) then
                        for _, gc in ipairs(state:get_children(c.path)) do
                            if gc.id then
                                if gc.id == nested.id then
                                    parsed[#parsed + 1] = { id = gc.id, path = to_path, type = gc.type }
                                else
                                    parsed[#parsed + 1] = { id = gc.id, path = gc.path, type = gc.type }
                                end
                            end
                        end
                    end
                end
                return parsed
            end

            -- Sync while both expanded
            full_sync(state, build_parsed_both_expanded())
            assert.equals(to_path, state.pending_moves[from_path], "move should exist after first sync")

            -- Collapse sibling (the DESTINATION directory)
            state:collapse(sibling)

            -- Build parsed after sibling collapsed (nested.txt no longer visible)
            local function build_parsed_sibling_collapsed()
                local parsed = {}
                local root = state:get_by_path(test_dir)
                parsed[#parsed + 1] = { id = root.id, path = root.path, type = "directory" }
                for _, c in ipairs(state:get_children(test_dir)) do
                    if c.id and c.id ~= nested.id then  -- nested is hidden (moved to collapsed sibling)
                        parsed[#parsed + 1] = { id = c.id, path = c.path, type = c.type }
                    end
                    if c.type == "directory" and state:is_expanded(c) then
                        for _, gc in ipairs(state:get_children(c.path)) do
                            if gc.id and gc.id ~= nested.id then
                                parsed[#parsed + 1] = { id = gc.id, path = gc.path, type = gc.type }
                            end
                        end
                    end
                end
                return parsed
            end

            -- Sync after collapse
            full_sync(state, build_parsed_sibling_collapsed())

            -- The pending move should be preserved (destination is under collapsed directory)
            assert.equals(to_path, state.pending_moves[from_path],
                "pending move should be preserved when destination dir is collapsed")
        end)

        it("should preserve pending deletes when collapsing parent directory", function()
            local state = State.new(test_dir)

            -- Expand child
            local child = state:get_by_path(test_dir .. "/child")
            state:expand(child)

            -- User deletes nested.txt
            local nested = state:get_by_path(test_dir .. "/child/nested.txt")
            assert.is_not_nil(nested)
            state:mark_delete(nested.path)
            assert.is_true(state:is_deleted(nested.path))

            -- Build parsed without the deleted file
            local function build_parsed_expanded()
                local parsed = {}
                local root = state:get_by_path(test_dir)
                parsed[#parsed + 1] = { id = root.id, path = root.path, type = "directory" }
                for _, c in ipairs(state:get_children(test_dir)) do
                    if c.id then
                        parsed[#parsed + 1] = { id = c.id, path = c.path, type = c.type }
                    end
                    if c.type == "directory" and state:is_expanded(c) then
                        for _, gc in ipairs(state:get_children(c.path)) do
                            if gc.id then
                                parsed[#parsed + 1] = { id = gc.id, path = gc.path, type = gc.type }
                            end
                        end
                    end
                end
                return parsed
            end

            -- Sync while expanded (delete is detected because nested.txt not in buffer)
            full_sync(state, build_parsed_expanded())
            assert.is_true(state:is_deleted(nested.path), "delete should exist after first sync")

            -- Collapse child
            state:collapse(child)

            -- Build parsed after collapse (child dir line, no children visible)
            local function build_parsed_collapsed()
                local parsed = {}
                local root = state:get_by_path(test_dir)
                parsed[#parsed + 1] = { id = root.id, path = root.path, type = "directory" }
                for _, c in ipairs(state:get_children(test_dir)) do
                    if c.id then
                        parsed[#parsed + 1] = { id = c.id, path = c.path, type = c.type }
                    end
                end
                return parsed
            end

            -- Sync after collapse
            full_sync(state, build_parsed_collapsed())

            -- The pending delete should be preserved (it's under collapsed directory)
            assert.is_true(state:is_deleted(nested.path),
                "pending delete should be preserved when parent dir is collapsed")
        end)

        it("should NOT preserve moves that are undone by user", function()
            local state = State.new(test_dir)

            -- Expand child
            local child = state:get_by_path(test_dir .. "/child")
            state:expand(child)

            -- User moves nested.txt
            local nested = state:get_by_path(test_dir .. "/child/nested.txt")
            local from_path = nested.path
            local to_path = test_dir .. "/child/renamed.txt"
            state:mark_move(from_path, to_path)

            -- Build parsed WITH the renamed file
            local function build_parsed_with_rename()
                local parsed = {}
                local root = state:get_by_path(test_dir)
                parsed[#parsed + 1] = { id = root.id, path = root.path, type = "directory" }
                for _, c in ipairs(state:get_children(test_dir)) do
                    if c.id then
                        parsed[#parsed + 1] = { id = c.id, path = c.path, type = c.type }
                    end
                    if c.type == "directory" and state:is_expanded(c) then
                        for _, gc in ipairs(state:get_children(c.path)) do
                            if gc.id then
                                if gc.id == nested.id then
                                    -- Show with new path
                                    parsed[#parsed + 1] = { id = gc.id, path = to_path, type = gc.type }
                                else
                                    parsed[#parsed + 1] = { id = gc.id, path = gc.path, type = gc.type }
                                end
                            end
                        end
                    end
                end
                return parsed
            end

            full_sync(state, build_parsed_with_rename())
            assert.equals(to_path, state.pending_moves[from_path])

            -- User undoes the rename (reverts to original name)
            -- Build parsed using ORIGINAL paths from state.entries, not get_children
            -- (get_children applies pending moves, but we want to show the reverted state)
            local function build_parsed_original()
                local parsed = {}
                local root = state:get_by_path(test_dir)
                parsed[#parsed + 1] = { id = root.id, path = root.path, type = "directory" }
                -- Add root children (but use original paths from state.entries)
                for _, entry in pairs(state.entries) do
                    if entry.parent_path == test_dir and not state:is_deleted(entry.path) then
                        parsed[#parsed + 1] = { id = entry.id, path = entry.path, type = entry.type }
                    end
                end
                -- Add child's children with ORIGINAL paths
                for _, entry in pairs(state.entries) do
                    if entry.parent_path == test_dir .. "/child" and not state:is_deleted(entry.path) then
                        -- Use entry.path (original), not effective path
                        parsed[#parsed + 1] = { id = entry.id, path = entry.path, type = entry.type }
                    end
                end
                return parsed
            end

            full_sync(state, build_parsed_original())

            -- Move should be gone (user reverted it)
            assert.is_nil(state.pending_moves[from_path],
                "move should be removed when user reverts to original name")
        end)

        it("should preserve moves through collapse/expand when source is visible", function()
            -- BUG: dd/p to move file to subdir, collapse/expand that subdir, file is gone
            -- The detection phase was overwriting restored moves with deletes
            local state = State.new(test_dir)

            -- Expand both directories
            local child = state:get_by_path(test_dir .. "/child")
            local sibling = state:get_by_path(test_dir .. "/sibling")
            state:expand(child)
            state:expand(sibling)

            -- Get nested.txt
            local nested = state:get_by_path(test_dir .. "/child/nested.txt")
            local from_path = nested.path
            local to_path = test_dir .. "/sibling/nested.txt"

            -- User moves file (dd then p)
            state:mark_move(from_path, to_path)

            -- Simulate buffer showing file under sibling (before collapse)
            local function build_parsed_with_move()
                local parsed = {}
                local root = state:get_by_path(test_dir)
                parsed[#parsed + 1] = { id = root.id, path = root.path, type = "directory" }
                for _, entry in pairs(state.entries) do
                    if entry.parent_path == test_dir then
                        parsed[#parsed + 1] = { id = entry.id, path = entry.path, type = entry.type }
                    end
                end
                -- child's children (excluding moved file)
                for _, entry in pairs(state.entries) do
                    if entry.parent_path == test_dir .. "/child" and entry.id ~= nested.id then
                        parsed[#parsed + 1] = { id = entry.id, path = entry.path, type = entry.type }
                    end
                end
                -- moved file appears under sibling
                parsed[#parsed + 1] = { id = nested.id, path = to_path, type = "file" }
                return parsed
            end

            -- Sync while both expanded (move detected)
            full_sync(state, build_parsed_with_move())
            assert.equals(to_path, state.pending_moves[from_path], "move should be detected")

            -- Collapse sibling
            state:collapse(sibling)

            -- Simulate buffer after collapse (file not visible, sibling collapsed)
            local function build_parsed_collapsed()
                local parsed = {}
                local root = state:get_by_path(test_dir)
                parsed[#parsed + 1] = { id = root.id, path = root.path, type = "directory" }
                for _, entry in pairs(state.entries) do
                    if entry.parent_path == test_dir then
                        parsed[#parsed + 1] = { id = entry.id, path = entry.path, type = entry.type }
                    end
                end
                -- child's children (excluding moved file - it's under collapsed sibling now)
                for _, entry in pairs(state.entries) do
                    if entry.parent_path == test_dir .. "/child" and entry.id ~= nested.id then
                        parsed[#parsed + 1] = { id = entry.id, path = entry.path, type = entry.type }
                    end
                end
                -- nested.txt NOT in parsed (sibling is collapsed)
                return parsed
            end

            -- Sync after collapse - this is where the bug was
            -- The move should be preserved, not overwritten with a delete
            full_sync(state, build_parsed_collapsed())

            -- Move should still exist, NOT replaced with delete
            assert.equals(to_path, state.pending_moves[from_path],
                "move should be preserved after collapse (not overwritten with delete)")
            assert.is_false(state:is_deleted(from_path),
                "entry should NOT be marked deleted when it has a pending move")
        end)

        it("should NOT preserve deletes that are undone by user", function()
            local state = State.new(test_dir)

            -- Expand child
            local child = state:get_by_path(test_dir .. "/child")
            state:expand(child)

            -- User deletes nested.txt
            local nested = state:get_by_path(test_dir .. "/child/nested.txt")
            state:mark_delete(nested.path)

            -- Build parsed WITHOUT the deleted file
            local function build_parsed_deleted()
                local parsed = {}
                local root = state:get_by_path(test_dir)
                parsed[#parsed + 1] = { id = root.id, path = root.path, type = "directory" }
                for _, c in ipairs(state:get_children(test_dir)) do
                    if c.id then
                        parsed[#parsed + 1] = { id = c.id, path = c.path, type = c.type }
                    end
                    if c.type == "directory" and state:is_expanded(c) then
                        for _, gc in ipairs(state:get_children(c.path)) do
                            -- Skip the deleted file
                            if gc.id and gc.id ~= nested.id then
                                parsed[#parsed + 1] = { id = gc.id, path = gc.path, type = gc.type }
                            end
                        end
                    end
                end
                return parsed
            end

            full_sync(state, build_parsed_deleted())
            assert.is_true(state:is_deleted(nested.path))

            -- User undoes the delete (re-adds the line)
            local function build_parsed_restored()
                local parsed = {}
                local root = state:get_by_path(test_dir)
                parsed[#parsed + 1] = { id = root.id, path = root.path, type = "directory" }
                for _, c in ipairs(state:get_children(test_dir)) do
                    if c.id then
                        parsed[#parsed + 1] = { id = c.id, path = c.path, type = c.type }
                    end
                    if c.type == "directory" and state:is_expanded(c) then
                        for _, gc in ipairs(state:get_children(c.path)) do
                            if gc.id then
                                parsed[#parsed + 1] = { id = gc.id, path = gc.path, type = gc.type }
                            end
                        end
                        -- Also include nested.txt that was restored
                        parsed[#parsed + 1] = { id = nested.id, path = nested.path, type = nested.type }
                    end
                end
                return parsed
            end

            full_sync(state, build_parsed_restored())

            -- Delete should be gone (user restored it)
            assert.is_false(state:is_deleted(nested.path),
                "delete should be removed when user restores the line")
        end)
    end)

    describe("diff.calculate with pending edits", function()
        local diff = require("sap.diff")

        it("should include pending_deletes in diff even when outside root", function()
            local state = State.new(test_dir)

            -- User deletes file.txt at parent level
            state:mark_delete(test_dir .. "/file.txt")

            -- Navigate to child
            local child = state:get_by_path(test_dir .. "/child")
            state:set_root(child)

            -- Now file.txt is "outside root"
            -- But pending_delete should still be preserved

            -- Parse buffer (only child contents)
            local parsed = {}
            parsed[#parsed + 1] = {
                id = child.id,
                path = child.path,
                name = child.name,
                type = "directory",
            }

            -- Calculate diff
            local changes = diff.calculate(state, parsed)

            -- Should include the pending delete for file.txt
            local has_file_delete = false
            for _, d in ipairs(changes.deletes) do
                if d.path == test_dir .. "/file.txt" then
                    has_file_delete = true
                    break
                end
            end
            assert.is_true(has_file_delete, "pending delete should be included in diff")
        end)

        it("should include pending_moves in diff even when outside root", function()
            local state = State.new(test_dir)

            -- User renames file at parent level
            state:mark_move(test_dir .. "/file.txt", test_dir .. "/renamed.txt")

            -- Navigate to child
            local child = state:get_by_path(test_dir .. "/child")
            state:set_root(child)

            local parsed = {}
            parsed[#parsed + 1] = {
                id = child.id,
                path = child.path,
                name = child.name,
                type = "directory",
            }

            local changes = diff.calculate(state, parsed)

            local has_move = false
            for _, m in ipairs(changes.moves) do
                if m.from == test_dir .. "/file.txt" then
                    has_move = true
                    break
                end
            end
            assert.is_true(has_move, "pending move should be included in diff")
        end)

        it("should include pending_creates in diff even when outside root", function()
            local state = State.new(test_dir)

            -- User creates file at parent level
            state:mark_create(test_dir .. "/newfile.txt", "file")

            -- Navigate to child
            local child = state:get_by_path(test_dir .. "/child")
            state:set_root(child)

            local parsed = {}
            parsed[#parsed + 1] = {
                id = child.id,
                path = child.path,
                name = child.name,
                type = "directory",
            }

            local changes = diff.calculate(state, parsed)

            local has_create = false
            for _, c in ipairs(changes.creates) do
                if c.path == test_dir .. "/newfile.txt" then
                    has_create = true
                    break
                end
            end
            assert.is_true(has_create, "pending create should be included in diff")
        end)
    end)
end)

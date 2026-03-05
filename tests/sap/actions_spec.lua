-- Integration tests for navigation actions
-- These tests simulate the full flow including buffer manipulation

describe("sap.actions integration", function()
    local State = require("sap.state")
    local buffer = require("sap.buffer")
    local parser = require("sap.parser")
    local test_dir

    local function setup_test_dir()
        local tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        vim.fn.mkdir(tmp .. "/child", "p")
        vim.fn.mkdir(tmp .. "/sibling", "p")
        vim.fn.writefile({}, tmp .. "/file.txt")
        vim.fn.writefile({}, tmp .. "/child/nested.txt")
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
        -- Clean up any test buffers
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if buffer.states[bufnr] then
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        end
    end)

    describe("parent -> child -> parent navigation", function()
        it("should preserve all entries after full navigation cycle", function()
            -- Create buffer starting in child directory
            local bufnr = buffer.create(test_dir .. "/child")
            assert.is_not_nil(bufnr)

            local state = buffer.states[bufnr]
            assert.is_not_nil(state)
            assert.equals(test_dir .. "/child", state.root_path)

            -- Simulate "go to parent" action
            state:go_to_parent()
            assert.equals(test_dir, state.root_path)

            -- Get children at parent level
            local children1 = state:get_children(test_dir)
            local names1 = {}
            for _, c in ipairs(children1) do
                names1[c.name] = true
            end

            assert.is_true(names1["child"], "child should be visible")
            assert.is_true(names1["sibling"], "sibling should be visible")
            assert.is_true(names1["file.txt"], "file.txt should be visible")

            -- Simulate "set root" to go back to child
            local child_entry = state:get_by_path(test_dir .. "/child")
            state:set_root(child_entry)
            assert.equals(test_dir .. "/child", state.root_path)

            -- Simulate sync() after set_root - siblings should be "intentionally hidden"
            -- (This is what buffer.sync does, but we're testing the state logic)
            state:clear_pending()
            -- At this point, sibling and file.txt are outside root, so not deleted

            -- Go back to parent
            state:go_to_parent()
            assert.equals(test_dir, state.root_path)

            -- Get children again
            local children2 = state:get_children(test_dir)
            local names2 = {}
            for _, c in ipairs(children2) do
                names2[c.name] = true
            end

            -- All entries should still be there
            assert.is_true(names2["child"], "child should still be visible")
            assert.is_true(names2["sibling"], "sibling should still be visible after navigation")
            assert.is_true(names2["file.txt"], "file.txt should still be visible after navigation")

            -- Count should be the same
            assert.equals(#children1, #children2, "should have same number of children")
        end)

        it("should preserve user deletions after navigation", function()
            local bufnr = buffer.create(test_dir .. "/child")
            local state = buffer.states[bufnr]

            -- Go to parent
            state:go_to_parent()

            -- User deletes file.txt
            state:mark_delete(test_dir .. "/file.txt")
            assert.is_true(state:is_deleted(test_dir .. "/file.txt"))

            -- Verify file is excluded from get_children
            local children1 = state:get_children(test_dir)
            local has_file = false
            for _, c in ipairs(children1) do
                if c.name == "file.txt" then has_file = true end
            end
            assert.is_false(has_file, "deleted file should not appear")

            -- Go to child
            local child_entry = state:get_by_path(test_dir .. "/child")
            state:set_root(child_entry)

            -- File.txt is now outside root, so it's "intentionally hidden"
            -- We DON'T want to clear pending_delete for it in a real sync

            -- Go back to parent
            state:go_to_parent()

            -- The deletion should NOT be preserved in state because sync clears pending
            -- But the file entry itself is still in state.entries
            -- This is where the bug was - sync was incorrectly clearing the deletion

            -- In the REAL implementation, sync() recalculates pending from buffer
            -- If file.txt was deleted from buffer, sync() would re-mark it as deleted
            -- The key is that sync() shouldn't mark siblings as deleted when they're outside root

            local children2 = state:get_children(test_dir)
            -- Note: without calling sync(), pending_delete is still set from earlier
            has_file = false
            for _, c in ipairs(children2) do
                if c.name == "file.txt" then has_file = true end
            end
            assert.is_false(has_file, "file should still be deleted")
        end)
    end)

    describe("buffer sync behavior", function()
        it("should detect deletions from buffer", function()
            local bufnr = buffer.create(test_dir)
            local state = buffer.states[bufnr]

            -- Get initial line count
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local initial_count = #lines

            -- Delete a line from buffer (simulating user action)
            vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, {})

            -- Call sync
            buffer.sync(bufnr)

            -- Should have marked something as deleted
            assert.is_true(state:has_pending_edits())
        end)

        it("should detect renames from buffer edits", function()
            local bufnr = buffer.create(test_dir)
            local state = buffer.states[bufnr]

            -- Find the file.txt line and rename it
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            for i, line in ipairs(lines) do
                if line:match("file%.txt") then
                    -- Replace "file.txt" with "renamed.txt" preserving the ID prefix
                    local new_line = line:gsub("file%.txt", "renamed.txt")
                    vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { new_line })
                    break
                end
            end

            buffer.sync(bufnr)

            -- Should have a pending move (rename)
            local has_move = false
            for from, to in pairs(state.pending_moves) do
                if from:match("file%.txt") and to:match("renamed%.txt") then
                    has_move = true
                end
            end
            assert.is_true(has_move, "should detect rename as move")
        end)

        it("should detect creates from new lines", function()
            local bufnr = buffer.create(test_dir)
            local state = buffer.states[bufnr]

            -- Add a new line without ID (simulating user adding new file)
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            -- Insert after first line (root) with proper indentation
            local new_line = "    newfile.txt"
            vim.api.nvim_buf_set_lines(bufnr, 1, 1, false, { new_line })

            buffer.sync(bufnr)

            -- Should have a pending create
            local has_create = false
            for path, _ in pairs(state.pending_creates) do
                if path:match("newfile%.txt") then
                    has_create = true
                end
            end
            assert.is_true(has_create, "should detect new line as create")
        end)
    end)

    describe("expand/collapse actions", function()
        it("should expand directory and show children", function()
            local bufnr = buffer.create(test_dir)
            local state = buffer.states[bufnr]

            -- Initially, child directory is collapsed
            local child = state:get_by_path(test_dir .. "/child")
            assert.is_false(state:is_expanded(child))

            -- Expand the child
            state:expand(child)
            assert.is_true(state:is_expanded(child))

            -- Re-render
            buffer.render(bufnr)

            -- Buffer should now show nested.txt
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local has_nested = false
            for _, line in ipairs(lines) do
                if line:match("nested%.txt") then
                    has_nested = true
                end
            end
            assert.is_true(has_nested, "expanded dir should show children")
        end)

        it("should collapse directory and hide children", function()
            local bufnr = buffer.create(test_dir)
            local state = buffer.states[bufnr]

            -- Expand then collapse
            local child = state:get_by_path(test_dir .. "/child")
            state:expand(child)
            buffer.render(bufnr)

            -- Verify nested is visible
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local nested_visible = false
            for _, line in ipairs(lines) do
                if line:match("nested%.txt") then
                    nested_visible = true
                end
            end
            assert.is_true(nested_visible, "nested should be visible before collapse")

            -- Collapse
            state:collapse(child)
            buffer.render(bufnr)

            -- Verify nested is hidden
            lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            nested_visible = false
            for _, line in ipairs(lines) do
                if line:match("nested%.txt") then
                    nested_visible = true
                end
            end
            assert.is_false(nested_visible, "nested should be hidden after collapse")
        end)
    end)

    describe("hidden files", function()
        local test_dir_with_hidden

        before_each(function()
            test_dir_with_hidden = vim.fn.tempname()
            vim.fn.mkdir(test_dir_with_hidden, "p")
            vim.fn.writefile({}, test_dir_with_hidden .. "/visible.txt")
            vim.fn.writefile({}, test_dir_with_hidden .. "/.hidden")
            vim.fn.mkdir(test_dir_with_hidden .. "/.hiddendir", "p")
        end)

        after_each(function()
            if test_dir_with_hidden then
                vim.fn.delete(test_dir_with_hidden, "rf")
            end
        end)

        it("should hide dotfiles when show_hidden is false", function()
            local state = State.new(test_dir_with_hidden, false)
            local children = state:get_children(test_dir_with_hidden)

            local names = {}
            for _, c in ipairs(children) do
                names[c.name] = true
            end

            assert.is_true(names["visible.txt"], "visible file should be shown")
            assert.is_nil(names[".hidden"], "hidden file should be hidden")
            assert.is_nil(names[".hiddendir"], "hidden dir should be hidden")
        end)

        it("should show dotfiles when show_hidden is true", function()
            local state = State.new(test_dir_with_hidden, true)
            local children = state:get_children(test_dir_with_hidden)

            local names = {}
            for _, c in ipairs(children) do
                names[c.name] = true
            end

            assert.is_true(names["visible.txt"], "visible file should be shown")
            assert.is_true(names[".hidden"], "hidden file should be shown")
            assert.is_true(names[".hiddendir"], "hidden dir should be shown")
        end)

        it("should toggle hidden files visibility", function()
            local state = State.new(test_dir_with_hidden, false)

            -- Initially hidden
            local children1 = state:get_children(test_dir_with_hidden)
            local has_hidden1 = false
            for _, c in ipairs(children1) do
                if c.name == ".hidden" then has_hidden1 = true end
            end
            assert.is_false(has_hidden1, "hidden file should be hidden initially")

            -- Toggle
            state.show_hidden = true

            local children2 = state:get_children(test_dir_with_hidden)
            local has_hidden2 = false
            for _, c in ipairs(children2) do
                if c.name == ".hidden" then has_hidden2 = true end
            end
            assert.is_true(has_hidden2, "hidden file should be visible after toggle")
        end)
    end)

    describe("refresh", function()
        it("should reload entries from filesystem", function()
            local bufnr = buffer.create(test_dir)
            local state = buffer.states[bufnr]

            -- Get initial children count
            local initial_count = #state:get_children(test_dir)

            -- Create a new file on the filesystem
            vim.fn.writefile({}, test_dir .. "/new_external.txt")

            -- Refresh state
            state:refresh()

            -- Should now have one more child
            local new_count = #state:get_children(test_dir)
            assert.equals(initial_count + 1, new_count, "should see new file after refresh")
        end)

        it("should clear pending edits on refresh", function()
            local bufnr = buffer.create(test_dir)
            local state = buffer.states[bufnr]

            -- Mark some pending edits
            state:mark_delete(test_dir .. "/file.txt")
            state:mark_create(test_dir .. "/pending.txt", "file")
            assert.is_true(state:has_pending_edits())

            -- Refresh
            state:refresh()

            -- Pending edits should be cleared
            assert.is_false(state:has_pending_edits(), "pending edits should be cleared after refresh")
        end)
    end)

    describe("set_root and parent", function()
        it("should change root to subdirectory", function()
            local bufnr = buffer.create(test_dir)
            local state = buffer.states[bufnr]

            assert.equals(test_dir, state.root_path)

            -- Set root to child
            local child = state:get_by_path(test_dir .. "/child")
            state:set_root(child)

            assert.equals(test_dir .. "/child", state.root_path)
        end)

        it("should go to parent directory", function()
            local bufnr = buffer.create(test_dir .. "/child")
            local state = buffer.states[bufnr]

            assert.equals(test_dir .. "/child", state.root_path)

            -- Go to parent
            state:go_to_parent()

            assert.equals(test_dir, state.root_path)
        end)

        it("should load children when setting root to unvisited directory", function()
            local bufnr = buffer.create(test_dir)
            local state = buffer.states[bufnr]

            -- child directory exists but hasn't been expanded
            local child = state:get_by_path(test_dir .. "/child")
            assert.is_not_nil(child)
            assert.is_false(state:is_expanded(child))

            -- Set root to child (without expanding first)
            state:set_root(child)

            -- Should now be expanded and have children loaded
            assert.is_true(state:is_expanded(child))

            -- Should have nested.txt as a child
            local children = state:get_children(test_dir .. "/child")
            local has_nested = false
            for _, c in ipairs(children) do
                if c.name == "nested.txt" then
                    has_nested = true
                end
            end
            assert.is_true(has_nested, "should load children when setting root to unvisited dir")
        end)

        it("should stop going to parent at filesystem root", function()
            -- Start at a deep path and go up until we can't anymore
            local state = State.new(test_dir)

            -- Keep going up until we hit root
            local max_iterations = 50  -- safety limit
            local iterations = 0
            while iterations < max_iterations do
                local ok, err = state:go_to_parent()
                if not ok then
                    -- We've hit the filesystem root
                    assert.is_truthy(err:match("root"))
                    break
                end
                iterations = iterations + 1
            end

            assert.is_true(iterations < max_iterations, "should eventually hit root")
            assert.is_true(iterations > 0, "should have gone up at least once")
        end)
    end)

    describe("indent/unindent helpers", function()
        it("should preserve ID prefix when indenting", function()
            local bufnr = buffer.create(test_dir)

            -- Get a line with an ID
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local test_line = nil
            local test_idx = nil
            for i, line in ipairs(lines) do
                if line:match("^///") and line:match("file%.txt") then
                    test_line = line
                    test_idx = i
                    break
                end
            end
            assert.is_not_nil(test_line, "should find a line with ID")

            -- Extract ID
            local id = test_line:match("^///(%d+):")
            assert.is_not_nil(id, "should extract ID from line")

            -- Manually indent (simulating shift_lines behavior)
            local prefix_end = test_line:find(":") or 0
            local before = test_line:sub(1, prefix_end)
            local after = test_line:sub(prefix_end + 1)
            local indented = before .. "    " .. after

            vim.api.nvim_buf_set_lines(bufnr, test_idx - 1, test_idx, false, { indented })

            -- Verify ID is preserved
            local new_line = vim.api.nvim_buf_get_lines(bufnr, test_idx - 1, test_idx, false)[1]
            local new_id = new_line:match("^///(%d+):")
            assert.equals(id, new_id, "ID should be preserved after indent")
        end)
    end)
end)

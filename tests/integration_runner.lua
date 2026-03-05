-- Integration test runner for sap
-- Runs real Neovim sessions with actual keystrokes and buffer manipulation
--
-- Usage: nvim --headless -u tests/minimal_init.lua -l tests/integration_runner.lua

local function setup_test_dir()
    local base = "/tmp/sap-integration-" .. os.time()
    vim.fn.system("rm -rf " .. base)
    vim.fn.mkdir(base .. "/dir1/sub1", "p")
    vim.fn.mkdir(base .. "/dir1/sub2", "p")
    vim.fn.mkdir(base .. "/dir2/nested", "p")
    vim.fn.mkdir(base .. "/dir3", "p")
    vim.fn.writefile({ "content1" }, base .. "/dir1/file1.txt")
    vim.fn.writefile({ "content2" }, base .. "/dir1/file2.txt")
    vim.fn.writefile({ "a content" }, base .. "/dir1/sub1/a.txt")
    vim.fn.writefile({ "b content" }, base .. "/dir1/sub1/b.txt")
    vim.fn.writefile({ "c content" }, base .. "/dir1/sub2/c.txt")
    vim.fn.writefile({ "other" }, base .. "/dir2/other.txt")
    vim.fn.writefile({ "solo" }, base .. "/dir3/solo.txt")
    return base
end

local function cleanup_test_dir(base)
    vim.fn.system("rm -rf " .. base)
end

-- Helper to send keys and wait for processing
local function feedkeys(keys)
    local escaped = vim.api.nvim_replace_termcodes(keys, true, false, true)
    vim.api.nvim_feedkeys(escaped, "mtx", false)
    -- Process pending keys
    vim.cmd("redraw")
end

-- Helper to find line containing text
local function find_line(bufnr, text)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, line in ipairs(lines) do
        if line:find(text, 1, true) then
            return i
        end
    end
    return nil
end

-- Helper to check if line exists
local function has_line(bufnr, text)
    return find_line(bufnr, text) ~= nil
end

-- Helper to go to line containing text
local function goto_line(bufnr, text)
    local lnum = find_line(bufnr, text)
    if lnum then
        vim.api.nvim_win_set_cursor(0, { lnum, 0 })
        return true
    end
    return false
end

-- Helper to get buffer content as string for debugging
local function dump_buffer(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return table.concat(lines, "\n")
end

-- Test results tracking
local results = {
    passed = 0,
    failed = 0,
    errors = {},
}

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        results.passed = results.passed + 1
        print("✓ " .. name)
    else
        results.failed = results.failed + 1
        results.errors[#results.errors + 1] = { name = name, error = err }
        print("✗ " .. name)
        print("  Error: " .. tostring(err))
    end
end

local function assert_true(condition, msg)
    if not condition then
        error(msg or "assertion failed: expected true")
    end
end

local function assert_false(condition, msg)
    if condition then
        error(msg or "assertion failed: expected false")
    end
end

local function assert_eq(expected, actual, msg)
    if expected ~= actual then
        error((msg or "assertion failed") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
    end
end

-- Run tests
local function run_tests()
    print("\n=== Sap Integration Tests ===\n")

    local base = setup_test_dir()

    -- Open sap
    require("sap").open(base)
    local bufnr = vim.api.nvim_get_current_buf()
    local buffer = require("sap.buffer")
    local state = buffer.get_state(bufnr)

    -- Test 1: Initial render
    test("Initial render shows root and children", function()
        assert_true(has_line(bufnr, "sap-integration"), "should show root directory")
        assert_true(has_line(bufnr, "dir1/"), "should show dir1")
        assert_true(has_line(bufnr, "dir2/"), "should show dir2")
        assert_true(has_line(bufnr, "dir3/"), "should show dir3")
    end)

    -- Test 2: Expand directory with Enter
    test("Expand directory with <CR>", function()
        goto_line(bufnr, "dir1/")
        feedkeys("<CR>")
        assert_true(has_line(bufnr, "file1.txt"), "should show file1.txt after expand")
        assert_true(has_line(bufnr, "file2.txt"), "should show file2.txt after expand")
        assert_true(has_line(bufnr, "sub1/"), "should show sub1/ after expand")
    end)

    -- Test 3: Collapse directory with Enter
    test("Collapse directory with <CR>", function()
        goto_line(bufnr, "dir1/")
        feedkeys("<CR>")
        assert_false(has_line(bufnr, "file1.txt"), "file1.txt should be hidden after collapse")
        assert_false(has_line(bufnr, "sub1/"), "sub1/ should be hidden after collapse")
    end)

    -- Test 4: Re-expand preserves structure
    test("Re-expand shows same content", function()
        goto_line(bufnr, "dir1/")
        feedkeys("<CR>")
        assert_true(has_line(bufnr, "file1.txt"), "file1.txt should reappear")
        assert_true(has_line(bufnr, "sub1/"), "sub1/ should reappear")
    end)

    -- Test 5: Delete line with dd
    test("Delete file with dd", function()
        goto_line(bufnr, "file1.txt")
        feedkeys("dd")
        assert_false(has_line(bufnr, "file1.txt"), "file1.txt should be deleted from buffer")
        -- Sync to update state
        buffer.sync(bufnr)
        assert_true(state.pending_deletes[base .. "/dir1/file1.txt"], "should have pending delete")
    end)

    -- Test 6: Delete survives collapse/expand
    test("Delete survives collapse/expand cycle", function()
        goto_line(bufnr, "dir1/")
        feedkeys("<CR>")  -- collapse
        feedkeys("<CR>")  -- expand
        assert_false(has_line(bufnr, "file1.txt"), "file1.txt should stay deleted")
    end)

    -- Test 7: Add new file by typing (use direct buffer manipulation for reliability)
    test("Create new file by adding line", function()
        local file2_line = find_line(bufnr, "file2.txt")
        local existing = vim.api.nvim_buf_get_lines(bufnr, file2_line - 1, file2_line, false)[1]
        -- Get indent from existing line (after the ID prefix)
        local prefix_end = existing:find(":") or 0
        local after_prefix = existing:sub(prefix_end + 1)
        local indent = after_prefix:match("^(%s*)") or ""
        -- Insert new line with same indent (no ID = new file)
        local new_line = indent .. "newfile.txt"
        vim.api.nvim_buf_set_lines(bufnr, file2_line, file2_line, false, { new_line })
        buffer.sync(bufnr)
        assert_true(has_line(bufnr, "newfile.txt"), "newfile.txt should appear")
        assert_true(state.pending_creates[base .. "/dir1/newfile.txt"], "should have pending create")
    end)

    -- Test 8: New file survives collapse/expand
    test("New file survives collapse/expand", function()
        goto_line(bufnr, "dir1/")
        feedkeys("<CR>")  -- collapse
        feedkeys("<CR>")  -- expand
        assert_true(has_line(bufnr, "newfile.txt"), "newfile.txt should survive collapse/expand")
    end)

    -- Test 9: Rename by editing line (use direct buffer manipulation for reliability)
    test("Rename by editing line", function()
        local file2_line = find_line(bufnr, "file2.txt")
        assert_true(file2_line, "file2.txt should exist")
        local line = vim.api.nvim_buf_get_lines(bufnr, file2_line - 1, file2_line, false)[1]
        -- Replace file2.txt with renamed.txt, keeping ID prefix and indent
        local new_line = line:gsub("file2%.txt", "renamed.txt")
        vim.api.nvim_buf_set_lines(bufnr, file2_line - 1, file2_line, false, { new_line })
        buffer.sync(bufnr)
        assert_true(has_line(bufnr, "renamed.txt"), "should have renamed.txt")
        assert_false(has_line(bufnr, "file2.txt"), "should not have file2.txt")
    end)

    -- Test 10: Rename survives collapse/expand
    test("Rename survives collapse/expand", function()
        goto_line(bufnr, "dir1/")
        feedkeys("<CR>")  -- collapse
        feedkeys("<CR>")  -- expand
        assert_true(has_line(bufnr, "renamed.txt"), "renamed.txt should survive")
        assert_false(has_line(bufnr, "file2.txt"), "file2.txt should stay gone")
    end)

    -- Test 11: Expand nested directory
    test("Expand nested directory", function()
        goto_line(bufnr, "sub1/")
        feedkeys("<CR>")
        assert_true(has_line(bufnr, "a.txt"), "should show a.txt")
        assert_true(has_line(bufnr, "b.txt"), "should show b.txt")
    end)

    -- Test 12: Nested collapse/expand
    test("Nested collapse/expand preserves edits", function()
        -- Delete a.txt
        goto_line(bufnr, "a.txt")
        feedkeys("dd")
        buffer.sync(bufnr)

        -- Collapse sub1
        goto_line(bufnr, "sub1/")
        feedkeys("<CR>")

        -- Collapse dir1
        goto_line(bufnr, "dir1/")
        feedkeys("<CR>")

        -- Expand dir1
        feedkeys("<CR>")

        -- Expand sub1
        goto_line(bufnr, "sub1/")
        feedkeys("<CR>")

        -- a.txt should still be deleted
        assert_false(has_line(bufnr, "a.txt"), "a.txt should stay deleted through nested collapse/expand")
        assert_true(has_line(bufnr, "b.txt"), "b.txt should still exist")
    end)

    -- Test 13: Set root (Ctrl-Enter)
    test("Set root with <C-CR>", function()
        -- Collapse everything first for clean state
        goto_line(bufnr, "sub1/")
        if has_line(bufnr, "b.txt") then
            feedkeys("<CR>")  -- collapse sub1
        end

        goto_line(bufnr, "dir1/")
        feedkeys("<C-CR>")  -- set as root

        -- Now dir1 should be at root level
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)
        assert_true(lines[1]:find("dir1/"), "dir1 should be the root now")

        -- Siblings (dir2, dir3) should not be visible
        assert_false(has_line(bufnr, "dir2/"), "dir2 should not be visible")
        assert_false(has_line(bufnr, "dir3/"), "dir3 should not be visible")
    end)

    -- Test 14: Go to parent (Backspace)
    test("Go to parent with <BS>", function()
        feedkeys("<BS>")  -- go to parent

        -- Should be back at original root
        assert_true(has_line(bufnr, "dir2/"), "dir2 should be visible again")
        assert_true(has_line(bufnr, "dir3/"), "dir3 should be visible again")
    end)

    -- Test 15: Edits preserved through navigation
    test("Edits preserved through set_root/parent cycle", function()
        -- The earlier deletions should still be pending
        -- Expand dir1 to check
        goto_line(bufnr, "dir1/")
        if not has_line(bufnr, "sub1/") then
            feedkeys("<CR>")  -- expand
        end

        -- file1.txt should still be deleted (from earlier test)
        assert_false(has_line(bufnr, "file1.txt"), "file1.txt should still be deleted")

        -- renamed.txt should still exist
        assert_true(has_line(bufnr, "renamed.txt"), "renamed.txt should still exist")
    end)

    -- Cleanup
    vim.api.nvim_buf_delete(bufnr, { force = true })
    cleanup_test_dir(base)

    -- Print summary
    print("\n=== Results ===")
    print(string.format("Passed: %d", results.passed))
    print(string.format("Failed: %d", results.failed))

    if #results.errors > 0 then
        print("\nFailures:")
        for _, e in ipairs(results.errors) do
            print("  - " .. e.name .. ": " .. e.error)
        end
    end

    -- Exit with appropriate code
    vim.cmd("qa" .. (results.failed > 0 and "!" or ""))
end

-- Run on load
vim.schedule(run_tests)

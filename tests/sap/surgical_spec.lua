-- Tests for surgical rendering (collapse/expand/navigate preserving edits)
local parser = require("sap.parser")
local constants = require("sap.constants")

-- Helper to create test directory
local function setup_test_dir()
    local base = "/tmp/sap-surgical-test-" .. os.time()
    vim.fn.system("rm -rf " .. base)
    vim.fn.mkdir(base .. "/dir1/sub1", "p")
    vim.fn.mkdir(base .. "/dir1/sub2", "p")
    vim.fn.mkdir(base .. "/dir2/nested", "p")
    vim.fn.mkdir(base .. "/dir3", "p")
    vim.fn.writefile({}, base .. "/dir1/file1.txt")
    vim.fn.writefile({}, base .. "/dir1/file2.txt")
    vim.fn.writefile({}, base .. "/dir1/sub1/a.txt")
    vim.fn.writefile({}, base .. "/dir1/sub1/b.txt")
    vim.fn.writefile({}, base .. "/dir1/sub2/c.txt")
    vim.fn.writefile({}, base .. "/dir2/nested/deep.txt")
    vim.fn.writefile({}, base .. "/dir2/other.txt")
    vim.fn.writefile({}, base .. "/dir3/solo.txt")
    return base
end

local function cleanup_test_dir(base)
    vim.fn.system("rm -rf " .. base)
end

-- Helper to find line number by path substring
local function find_line_with_path(bufnr, path_part)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, line in ipairs(lines) do
        if line:find(path_part, 1, true) then
            return i
        end
    end
    return nil
end

-- Helper to find line by entry name
local function find_line_with_name(bufnr, name)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, line in ipairs(lines) do
        local _, _, parsed_name = parser.parse_line(line)
        if parsed_name == name then
            return i
        end
    end
    return nil
end

-- Helper to count visible lines matching pattern
local function count_lines_matching(bufnr, pattern)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local count = 0
    for _, line in ipairs(lines) do
        if line:find(pattern, 1, true) then
            count = count + 1
        end
    end
    return count
end

-- Helper to add a new line after a given line number
local function add_line_after(bufnr, after_line, content)
    vim.api.nvim_buf_set_lines(bufnr, after_line, after_line, false, { content })
end

-- Helper to delete a line
local function delete_line(bufnr, line_num)
    vim.api.nvim_buf_set_lines(bufnr, line_num - 1, line_num, false, {})
end

-- Helper to get indent size from config
local function get_indent()
    local config = require("sap.config")
    return string.rep(" ", config.options.indent_size or 4)
end

describe("sap.surgical", function()
    local base, bufnr, state, render, buffer

    before_each(function()
        -- Clear module cache for fresh state
        for k in pairs(package.loaded) do
            if k:match("^sap") then
                package.loaded[k] = nil
            end
        end

        render = require("sap.render")
        buffer = require("sap.buffer")

        base = setup_test_dir()
        bufnr = buffer.create(base)
        state = buffer.get_state(bufnr)
        vim.api.nvim_set_current_buf(bufnr)
    end)

    after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        cleanup_test_dir(base)
    end)

    describe("collapse/expand", function()
        it("should preserve buffer structure through collapse/expand cycle", function()
            -- Expand dir1
            local dir1 = state:get_by_path(base .. "/dir1")
            assert.is_not_nil(dir1, "dir1 should exist")
            render.expand(bufnr, state, dir1)

            -- Count lines before
            local lines_before = vim.api.nvim_buf_line_count(bufnr)
            local has_file1 = find_line_with_name(bufnr, "file1.txt")
            assert.is_not_nil(has_file1, "file1.txt should be visible after expand")

            -- Collapse
            render.collapse(bufnr, state, dir1)
            local lines_collapsed = vim.api.nvim_buf_line_count(bufnr)
            assert.is_true(lines_collapsed < lines_before, "line count should decrease after collapse")

            -- Expand again
            render.expand(bufnr, state, dir1)
            local lines_after = vim.api.nvim_buf_line_count(bufnr)
            assert.equals(lines_before, lines_after, "line count should match after expand")

            has_file1 = find_line_with_name(bufnr, "file1.txt")
            assert.is_not_nil(has_file1, "file1.txt should be visible after re-expand")
        end)

        it("should preserve pending creates through collapse/expand", function()
            -- Expand dir1
            local dir1 = state:get_by_path(base .. "/dir1")
            render.expand(bufnr, state, dir1)

            -- Find last child of dir1 and add new file after it
            -- Children of dir1 are at depth 2 (root=0, dir1=1, children=2)
            local file2_line = find_line_with_name(bufnr, "file2.txt")
            assert.is_not_nil(file2_line, "file2.txt should exist")

            -- Get the actual indent from an existing child line
            local existing_line = vim.api.nvim_buf_get_lines(bufnr, file2_line - 1, file2_line, false)[1]
            local _, existing_indent = parser.parse_line(existing_line)
            local indent = string.rep(" ", existing_indent)

            add_line_after(bufnr, file2_line, indent .. "newfile.txt")

            -- Sync to register the create
            buffer.sync(bufnr)
            assert.is_not_nil(state.pending_creates[base .. "/dir1/newfile.txt"],
                "create should be registered")

            -- Collapse and expand
            render.collapse(bufnr, state, dir1)
            render.expand(bufnr, state, dir1)

            -- Check new file still visible
            local newfile_line = find_line_with_name(bufnr, "newfile.txt")
            assert.is_not_nil(newfile_line, "newfile.txt should survive collapse/expand")
        end)

        it("should preserve pending deletes through collapse/expand", function()
            -- Expand dir1
            local dir1 = state:get_by_path(base .. "/dir1")
            render.expand(bufnr, state, dir1)

            -- Delete file1.txt
            local file1_line = find_line_with_name(bufnr, "file1.txt")
            assert.is_not_nil(file1_line)
            delete_line(bufnr, file1_line)

            -- Sync to register the delete
            buffer.sync(bufnr)
            assert.is_true(state.pending_deletes[base .. "/dir1/file1.txt"] == true,
                "delete should be registered")

            -- Collapse and expand
            render.collapse(bufnr, state, dir1)
            render.expand(bufnr, state, dir1)

            -- file1.txt should still be deleted (not visible)
            file1_line = find_line_with_name(bufnr, "file1.txt")
            assert.is_nil(file1_line, "file1.txt should stay deleted after collapse/expand")
        end)

        it("should preserve line edits (renames) through collapse/expand", function()
            -- Expand dir1
            local dir1 = state:get_by_path(base .. "/dir1")
            render.expand(bufnr, state, dir1)

            -- Find file1.txt and rename it
            local file1_line = find_line_with_name(bufnr, "file1.txt")
            assert.is_not_nil(file1_line)

            -- Get the line, modify the name
            local line = vim.api.nvim_buf_get_lines(bufnr, file1_line - 1, file1_line, false)[1]
            local new_line = line:gsub("file1%.txt", "renamed.txt")
            vim.api.nvim_buf_set_lines(bufnr, file1_line - 1, file1_line, false, { new_line })

            -- Collapse and expand (no sync needed - raw line is stored)
            render.collapse(bufnr, state, dir1)
            render.expand(bufnr, state, dir1)

            -- renamed.txt should be visible
            local renamed_line = find_line_with_name(bufnr, "renamed.txt")
            assert.is_not_nil(renamed_line, "renamed.txt should survive collapse/expand")

            -- file1.txt should not be visible (it was renamed)
            file1_line = find_line_with_name(bufnr, "file1.txt")
            assert.is_nil(file1_line, "file1.txt should not exist (was renamed)")
        end)

        it("should preserve moves via indent change through collapse/expand", function()
            -- Expand dir1 and sub1
            local dir1 = state:get_by_path(base .. "/dir1")
            render.expand(bufnr, state, dir1)

            local sub1 = state:get_by_path(base .. "/dir1/sub1")
            render.expand(bufnr, state, sub1)

            -- Find a.txt (under sub1) and unindent it (move to dir1)
            local a_line = find_line_with_name(bufnr, "a.txt")
            assert.is_not_nil(a_line)

            local line = vim.api.nvim_buf_get_lines(bufnr, a_line - 1, a_line, false)[1]
            -- Remove one indent level
            local indent = get_indent()
            local new_line = line:gsub(indent .. indent, indent, 1)
            vim.api.nvim_buf_set_lines(bufnr, a_line - 1, a_line, false, { new_line })

            -- Collapse sub1 (a.txt is now under dir1, not sub1)
            render.collapse(bufnr, state, sub1)

            -- a.txt should still be visible (it's under dir1 now, not collapsed sub1)
            a_line = find_line_with_name(bufnr, "a.txt")
            assert.is_not_nil(a_line, "a.txt should be visible (moved to dir1)")
        end)

        it("should handle nested collapse/expand", function()
            -- Expand dir1, then sub1
            local dir1 = state:get_by_path(base .. "/dir1")
            render.expand(bufnr, state, dir1)

            local sub1 = state:get_by_path(base .. "/dir1/sub1")
            render.expand(bufnr, state, sub1)

            -- Delete a.txt
            local a_line = find_line_with_name(bufnr, "a.txt")
            delete_line(bufnr, a_line)
            buffer.sync(bufnr)

            -- Collapse sub1
            render.collapse(bufnr, state, sub1)

            -- Collapse dir1
            render.collapse(bufnr, state, dir1)

            -- Expand dir1
            render.expand(bufnr, state, dir1)

            -- Expand sub1
            render.expand(bufnr, state, sub1)

            -- a.txt should still be deleted
            a_line = find_line_with_name(bufnr, "a.txt")
            assert.is_nil(a_line, "a.txt should stay deleted through nested collapse/expand")

            -- b.txt should be visible
            local b_line = find_line_with_name(bufnr, "b.txt")
            assert.is_not_nil(b_line, "b.txt should be visible")
        end)
    end)

    describe("navigation", function()
        it("should preserve edits when navigating to parent", function()
            -- Use existing buffer from before_each but set root to dir1 first
            local dir1 = state:get_by_path(base .. "/dir1")
            render.expand(bufnr, state, dir1)
            render.set_root(bufnr, state, dir1)

            -- Now root is dir1, buffer shows dir1's contents
            -- Delete file1.txt
            local file1_line = find_line_with_name(bufnr, "file1.txt")
            assert.is_not_nil(file1_line, "file1.txt should be visible initially")
            delete_line(bufnr, file1_line)
            buffer.sync(bufnr)

            -- Go to parent (back to base)
            render.go_to_parent(bufnr, state)

            -- Find and expand dir1 again to see its children
            dir1 = state:get_by_path(base .. "/dir1")
            assert.is_not_nil(dir1)
            if not state:is_expanded(dir1) then
                render.expand(bufnr, state, dir1)
            end

            -- file1.txt should still be deleted
            file1_line = find_line_with_name(bufnr, "file1.txt")
            assert.is_nil(file1_line, "file1.txt should stay deleted after parent navigation")
        end)

        it("should preserve edits when setting root", function()
            -- Expand dir1
            local dir1 = state:get_by_path(base .. "/dir1")
            render.expand(bufnr, state, dir1)

            -- Delete file1.txt
            local file1_line = find_line_with_name(bufnr, "file1.txt")
            delete_line(bufnr, file1_line)
            buffer.sync(bufnr)

            -- Set dir1 as root
            render.set_root(bufnr, state, dir1)

            -- file1.txt should still be deleted
            file1_line = find_line_with_name(bufnr, "file1.txt")
            assert.is_nil(file1_line, "file1.txt should stay deleted after set_root")
        end)

        it("should handle round-trip navigation (set_root then parent)", function()
            -- Expand dir1
            local dir1 = state:get_by_path(base .. "/dir1")
            render.expand(bufnr, state, dir1)

            -- Delete file1.txt
            local file1_line = find_line_with_name(bufnr, "file1.txt")
            delete_line(bufnr, file1_line)
            buffer.sync(bufnr)

            -- Set dir1 as root
            render.set_root(bufnr, state, dir1)

            -- Go back to parent
            render.go_to_parent(bufnr, state)

            -- Expand dir1 again
            dir1 = state:get_by_path(base .. "/dir1")
            if not state:is_expanded(dir1) then
                render.expand(bufnr, state, dir1)
            end

            -- file1.txt should still be deleted
            file1_line = find_line_with_name(bufnr, "file1.txt")
            assert.is_nil(file1_line, "file1.txt should stay deleted after round-trip")
        end)
    end)

    describe("hidden_content storage", function()
        it("should store and retrieve hidden content", function()
            -- Expand dir1
            local dir1 = state:get_by_path(base .. "/dir1")
            render.expand(bufnr, state, dir1)

            -- Collapse dir1
            render.collapse(bufnr, state, dir1)

            -- Check hidden_content
            local hidden = state:get_hidden_content(base .. "/dir1")
            assert.is_not_nil(hidden, "hidden_content should exist")
            assert.is_true(#hidden > 0, "hidden_content should have entries")

            -- Check entries have required fields
            for _, h in ipairs(hidden) do
                assert.is_not_nil(h.line, "hidden entry should have line")
                assert.is_not_nil(h.path, "hidden entry should have path")
                assert.is_not_nil(h.name, "hidden entry should have name")
                assert.is_not_nil(h.type, "hidden entry should have type")
            end
        end)

        it("should clear hidden content after expand", function()
            -- Expand dir1
            local dir1 = state:get_by_path(base .. "/dir1")
            render.expand(bufnr, state, dir1)

            -- Collapse dir1
            render.collapse(bufnr, state, dir1)
            assert.is_not_nil(state:get_hidden_content(base .. "/dir1"))

            -- Expand dir1
            render.expand(bufnr, state, dir1)

            -- Hidden content should be cleared
            local hidden = state:get_hidden_content(base .. "/dir1")
            assert.is_nil(hidden, "hidden_content should be cleared after expand")
        end)

        it("should include hidden content in save diff", function()
            -- Expand dir1
            local dir1 = state:get_by_path(base .. "/dir1")
            render.expand(bufnr, state, dir1)

            -- Rename file1.txt
            local file1_line = find_line_with_name(bufnr, "file1.txt")
            local line = vim.api.nvim_buf_get_lines(bufnr, file1_line - 1, file1_line, false)[1]
            local new_line = line:gsub("file1%.txt", "renamed.txt")
            vim.api.nvim_buf_set_lines(bufnr, file1_line - 1, file1_line, false, { new_line })

            -- Collapse dir1 (line with rename goes to hidden_content)
            render.collapse(bufnr, state, dir1)

            -- Get all hidden content
            local all_hidden = state:get_all_hidden_content()
            assert.is_true(#all_hidden > 0, "should have hidden content")

            -- Check that renamed.txt is in hidden content
            local found_renamed = false
            for _, h in ipairs(all_hidden) do
                if h.name == "renamed.txt" or h.path:match("renamed%.txt$") then
                    found_renamed = true
                    break
                end
            end
            assert.is_true(found_renamed, "renamed.txt should be in hidden content")
        end)
    end)
end)

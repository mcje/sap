-- Tests for diff calculation
-- Run with: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/sap/diff_spec.lua"

describe("sap.diff", function()
    local State = require("sap.state")
    local diff = require("sap.diff")
    local test_dir

    local function setup_test_dir()
        local tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        vim.fn.mkdir(tmp .. "/src", "p")
        vim.fn.writefile({}, tmp .. "/file1.txt")
        vim.fn.writefile({}, tmp .. "/file2.txt")
        vim.fn.writefile({}, tmp .. "/src/main.lua")
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

    describe("calculate", function()
        it("should detect no changes when buffer matches state", function()
            local state = State.new(test_dir)

            -- Build parsed that matches state exactly
            local root = state:get_by_path(test_dir)
            local parsed = {
                { id = root.id, path = test_dir, type = "directory" },
            }
            for _, c in ipairs(state:get_children(test_dir)) do
                parsed[#parsed + 1] = { id = c.id, path = c.path, type = c.type }
            end

            local changes = diff.calculate(state, parsed)

            assert.is_true(diff.is_empty(changes))
        end)

        it("should detect creates for lines without IDs", function()
            local state = State.new(test_dir)
            local root = state:get_by_path(test_dir)

            local parsed = {
                { id = root.id, path = test_dir, type = "directory" },
                { id = nil, path = test_dir .. "/newfile.txt", type = "file" },
            }

            local changes = diff.calculate(state, parsed)

            assert.equals(1, #changes.creates)
            assert.equals(test_dir .. "/newfile.txt", changes.creates[1].path)
            assert.equals("file", changes.creates[1].type)
        end)

        it("should detect creates for directories", function()
            local state = State.new(test_dir)
            local root = state:get_by_path(test_dir)

            local parsed = {
                { id = root.id, path = test_dir, type = "directory" },
                { id = nil, path = test_dir .. "/newdir", type = "directory" },
            }

            local changes = diff.calculate(state, parsed)

            assert.equals(1, #changes.creates)
            assert.equals(test_dir .. "/newdir", changes.creates[1].path)
            assert.equals("directory", changes.creates[1].type)
        end)

        it("should detect deletes for missing entries", function()
            local state = State.new(test_dir)
            local root = state:get_by_path(test_dir)
            local file1 = state:get_by_path(test_dir .. "/file1.txt")

            -- Parsed without file1.txt (user deleted the line)
            local parsed = {
                { id = root.id, path = test_dir, type = "directory" },
            }
            for _, c in ipairs(state:get_children(test_dir)) do
                if c.name ~= "file1.txt" then
                    parsed[#parsed + 1] = { id = c.id, path = c.path, type = c.type }
                end
            end

            local changes = diff.calculate(state, parsed)

            assert.equals(1, #changes.deletes)
            assert.equals(test_dir .. "/file1.txt", changes.deletes[1].path)
        end)

        it("should detect moves (renames)", function()
            local state = State.new(test_dir)
            local root = state:get_by_path(test_dir)
            local file1 = state:get_by_path(test_dir .. "/file1.txt")

            -- file1.txt renamed to renamed.txt (same ID, different path)
            local parsed = {
                { id = root.id, path = test_dir, type = "directory" },
                { id = file1.id, path = test_dir .. "/renamed.txt", type = "file" },
            }
            for _, c in ipairs(state:get_children(test_dir)) do
                if c.name ~= "file1.txt" then
                    parsed[#parsed + 1] = { id = c.id, path = c.path, type = c.type }
                end
            end

            local changes = diff.calculate(state, parsed)

            assert.equals(1, #changes.moves)
            assert.equals(test_dir .. "/file1.txt", changes.moves[1].from)
            assert.equals(test_dir .. "/renamed.txt", changes.moves[1].to)
        end)

        it("should detect moves (different directory)", function()
            local state = State.new(test_dir)
            local src = state:get_by_path(test_dir .. "/src")
            state:expand(src)

            local root = state:get_by_path(test_dir)
            local file1 = state:get_by_path(test_dir .. "/file1.txt")

            -- file1.txt moved into src/ (same ID, different parent)
            local parsed = {
                { id = root.id, path = test_dir, type = "directory" },
                { id = src.id, path = test_dir .. "/src", type = "directory" },
                { id = file1.id, path = test_dir .. "/src/file1.txt", type = "file" },
            }
            for _, c in ipairs(state:get_children(test_dir)) do
                if c.name ~= "file1.txt" and c.name ~= "src" then
                    parsed[#parsed + 1] = { id = c.id, path = c.path, type = c.type }
                end
            end
            for _, c in ipairs(state:get_children(test_dir .. "/src")) do
                parsed[#parsed + 1] = { id = c.id, path = c.path, type = c.type }
            end

            local changes = diff.calculate(state, parsed)

            assert.equals(1, #changes.moves)
            assert.equals(test_dir .. "/file1.txt", changes.moves[1].from)
            assert.equals(test_dir .. "/src/file1.txt", changes.moves[1].to)
        end)

        it("should detect copies (duplicate ID with original staying)", function()
            local state = State.new(test_dir)
            local root = state:get_by_path(test_dir)
            local file1 = state:get_by_path(test_dir .. "/file1.txt")

            -- file1.txt appears twice: original + copy (yank/paste)
            local parsed = {
                { id = root.id, path = test_dir, type = "directory" },
                { id = file1.id, path = test_dir .. "/file1.txt", type = "file" },  -- original
                { id = file1.id, path = test_dir .. "/file1_copy.txt", type = "file" },  -- copy
            }
            for _, c in ipairs(state:get_children(test_dir)) do
                if c.name ~= "file1.txt" then
                    parsed[#parsed + 1] = { id = c.id, path = c.path, type = c.type }
                end
            end

            local changes = diff.calculate(state, parsed)

            assert.equals(0, #changes.moves, "should not have moves")
            assert.equals(1, #changes.copies, "should have one copy")
            assert.equals(test_dir .. "/file1.txt", changes.copies[1].from)
            assert.equals(test_dir .. "/file1_copy.txt", changes.copies[1].to)
        end)

        it("should include pending_deletes in diff", function()
            local state = State.new(test_dir)
            local root = state:get_by_path(test_dir)

            -- Mark file as deleted via pending (not from buffer)
            state:mark_delete(test_dir .. "/file1.txt")

            -- Parsed shows the file as still there (but pending says delete)
            local parsed = {
                { id = root.id, path = test_dir, type = "directory" },
            }
            for _, c in ipairs(state:get_children(test_dir)) do
                parsed[#parsed + 1] = { id = c.id, path = c.path, type = c.type }
            end

            local changes = diff.calculate(state, parsed)

            -- Should include the pending delete
            local has_file1_delete = false
            for _, d in ipairs(changes.deletes) do
                if d.path == test_dir .. "/file1.txt" then
                    has_file1_delete = true
                end
            end
            assert.is_true(has_file1_delete, "pending delete should be in diff")
        end)

        it("should include pending_moves in diff", function()
            local state = State.new(test_dir)
            local root = state:get_by_path(test_dir)

            -- Mark file as moved via pending
            state:mark_move(test_dir .. "/file1.txt", test_dir .. "/moved.txt")

            local parsed = {
                { id = root.id, path = test_dir, type = "directory" },
            }

            local changes = diff.calculate(state, parsed)

            local has_move = false
            for _, m in ipairs(changes.moves) do
                if m.from == test_dir .. "/file1.txt" and m.to == test_dir .. "/moved.txt" then
                    has_move = true
                end
            end
            assert.is_true(has_move, "pending move should be in diff")
        end)

        it("should include pending_creates in diff", function()
            local state = State.new(test_dir)
            local root = state:get_by_path(test_dir)

            -- Mark file as created via pending
            state:mark_create(test_dir .. "/pending_new.txt", "file")

            local parsed = {
                { id = root.id, path = test_dir, type = "directory" },
            }

            local changes = diff.calculate(state, parsed)

            local has_create = false
            for _, c in ipairs(changes.creates) do
                if c.path == test_dir .. "/pending_new.txt" then
                    has_create = true
                end
            end
            assert.is_true(has_create, "pending create should be in diff")
        end)

        it("should not duplicate entries from buffer and pending", function()
            local state = State.new(test_dir)
            local root = state:get_by_path(test_dir)

            -- Create appears both in parsed (no ID) and pending
            local new_path = test_dir .. "/newfile.txt"
            state:mark_create(new_path, "file")

            local parsed = {
                { id = root.id, path = test_dir, type = "directory" },
                { id = nil, path = new_path, type = "file" },  -- also in buffer
            }

            local changes = diff.calculate(state, parsed)

            -- Should only appear once
            local count = 0
            for _, c in ipairs(changes.creates) do
                if c.path == new_path then
                    count = count + 1
                end
            end
            assert.equals(1, count, "create should appear exactly once")
        end)

        it("should not mark hidden entries as deleted", function()
            local state = State.new(test_dir)
            local src = state:get_by_path(test_dir .. "/src")
            state:expand(src)  -- Load children
            state:collapse(src)  -- Then collapse

            local root = state:get_by_path(test_dir)

            -- Parsed only shows root level (src collapsed, so main.lua not visible)
            local parsed = {
                { id = root.id, path = test_dir, type = "directory" },
            }
            for _, c in ipairs(state:get_children(test_dir)) do
                parsed[#parsed + 1] = { id = c.id, path = c.path, type = c.type }
            end

            local changes = diff.calculate(state, parsed)

            -- main.lua should NOT be marked as deleted (it's under collapsed dir)
            for _, d in ipairs(changes.deletes) do
                assert.is_not.equals(test_dir .. "/src/main.lua", d.path,
                    "hidden entry should not be marked as deleted")
            end
        end)
    end)

    describe("is_empty", function()
        it("should return true for empty changes", function()
            local changes = {
                creates = {},
                moves = {},
                copies = {},
                deletes = {},
            }
            assert.is_true(diff.is_empty(changes))
        end)

        it("should return false when there are creates", function()
            local changes = {
                creates = { { path = "/foo", type = "file" } },
                moves = {},
                copies = {},
                deletes = {},
            }
            assert.is_false(diff.is_empty(changes))
        end)

        it("should return false when there are deletes", function()
            local changes = {
                creates = {},
                moves = {},
                copies = {},
                deletes = { { path = "/foo", type = "file" } },
            }
            assert.is_false(diff.is_empty(changes))
        end)
    end)
end)

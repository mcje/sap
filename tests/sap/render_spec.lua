-- Tests for render module, particularly guide truncation
-- Run with: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/sap/render_spec.lua"

describe("sap.render", function()
    local config = require("sap.config")

    describe("guide truncation logic", function()
        -- Test the truncation algorithm used in decoration provider
        local function truncate_guide(guide, max_width)
            local guide_width = vim.fn.strdisplaywidth(guide)
            if guide_width <= max_width then
                return guide
            end

            local chars = vim.fn.split(guide, "\\zs")
            local truncated = {}
            local width = 0
            for _, char in ipairs(chars) do
                local char_width = vim.fn.strdisplaywidth(char)
                if width + char_width > max_width then
                    break
                end
                truncated[#truncated + 1] = char
                width = width + char_width
            end
            return table.concat(truncated)
        end

        it("should not truncate guide that fits within indent", function()
            local guide = "├── "
            local indent = 8
            local result = truncate_guide(guide, indent)
            assert.equals(guide, result)
        end)

        it("should truncate guide that exceeds indent", function()
            local guide = "│   ├── "  -- 8 chars wide
            local indent = 4
            local result = truncate_guide(guide, indent)
            assert.equals(4, vim.fn.strdisplaywidth(result))
        end)

        it("should handle unicode box-drawing characters", function()
            local guide = "├"  -- single unicode char
            local indent = 1
            local result = truncate_guide(guide, indent)
            assert.equals("├", result)
        end)

        it("should return empty string when indent is 0", function()
            local guide = "├── "
            local indent = 0
            local result = truncate_guide(guide, indent)
            assert.equals("", result)
        end)

        it("should handle deeply nested guides", function()
            -- Guide for depth 3: "│   │   └── "
            local guide = "│   │   └── "
            local expected_width = vim.fn.strdisplaywidth(guide)
            assert.equals(12, expected_width)

            -- If user unindents to depth 2 (8 spaces), truncate
            local result = truncate_guide(guide, 8)
            assert.equals(8, vim.fn.strdisplaywidth(result))

            -- Should be "│   │   " (first 8 chars)
            assert.equals("│   │   ", result)
        end)

        it("should handle single-char guide icons from config", function()
            -- Default config uses single-char icons: ├, └, │, space
            local icons = config.defaults.guides.icons
            local indent_size = config.defaults.indent_size

            -- Build a depth-2 guide with single-char icons
            local function pad_icon(icon)
                local icon_width = vim.fn.strdisplaywidth(icon)
                if icon_width < indent_size then
                    return icon .. string.rep(" ", indent_size - icon_width)
                end
                return icon
            end

            local guide = pad_icon(icons.pipe) .. pad_icon(icons.last)
            -- Should be "│   └   " with indent_size=4

            -- Full indent (8) should show full guide
            local result_full = truncate_guide(guide, 8)
            assert.equals(guide, result_full)

            -- Half indent (4) should show first segment
            local result_half = truncate_guide(guide, 4)
            assert.equals(4, vim.fn.strdisplaywidth(result_half))
        end)
    end)

    describe("flatten", function()
        local State = require("sap.state")
        local render = require("sap.render")
        local test_dir

        local function setup_test_dir()
            local tmp = vim.fn.tempname()
            vim.fn.mkdir(tmp, "p")
            vim.fn.mkdir(tmp .. "/a", "p")
            vim.fn.mkdir(tmp .. "/b", "p")
            vim.fn.writefile({}, tmp .. "/a/file1.txt")
            vim.fn.writefile({}, tmp .. "/a/file2.txt")
            vim.fn.writefile({}, tmp .. "/b/file3.txt")
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

        it("should mark last children correctly", function()
            local state = State.new(test_dir)

            -- Expand both directories
            local dir_a = state:get_by_path(test_dir .. "/a")
            local dir_b = state:get_by_path(test_dir .. "/b")
            state:expand(dir_a)
            state:expand(dir_b)

            local entries = render.flatten(state)

            -- Find entries and check is_last
            for _, e in ipairs(entries) do
                if e.entry.name == "a" then
                    -- 'a' is not the last sibling (b comes after)
                    assert.is_false(e.is_last, "dir 'a' should not be last")
                elseif e.entry.name == "b" then
                    -- 'b' is the last sibling at depth 1
                    assert.is_true(e.is_last, "dir 'b' should be last")
                elseif e.entry.name == "file2.txt" then
                    -- file2.txt is the last child of 'a'
                    assert.is_true(e.is_last, "file2.txt should be last in 'a'")
                elseif e.entry.name == "file3.txt" then
                    -- file3.txt is the last (and only) child of 'b'
                    assert.is_true(e.is_last, "file3.txt should be last in 'b'")
                end
            end
        end)

        it("should track ancestors_last for proper guide building", function()
            local state = State.new(test_dir)

            local dir_a = state:get_by_path(test_dir .. "/a")
            state:expand(dir_a)

            local entries = render.flatten(state)

            -- file1.txt is under 'a' which is NOT last sibling
            for _, e in ipairs(entries) do
                if e.entry.name == "file1.txt" then
                    -- depth is 2, ancestors_last[1] should be false (a is not last)
                    assert.is_false(e.ancestors_last[1],
                        "file1's parent (a) is not last sibling")
                end
            end
        end)
    end)
end)

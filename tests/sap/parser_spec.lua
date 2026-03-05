-- Run with: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/sap/parser_spec.lua"

describe("sap.parser", function()
    local parser = require("sap.parser")

    describe("parse_line", function()
        it("should parse line with ID prefix", function()
            local id, indent, name, ftype = parser.parse_line("///123:file.txt")
            assert.equals(123, id)
            assert.equals(0, indent)
            assert.equals("file.txt", name)
            assert.equals("file", ftype)
        end)

        it("should parse line without ID prefix", function()
            local id, indent, name, ftype = parser.parse_line("file.txt")
            assert.is_nil(id)
            assert.equals(0, indent)
            assert.equals("file.txt", name)
            assert.equals("file", ftype)
        end)

        it("should detect directory from trailing slash", function()
            local id, indent, name, ftype = parser.parse_line("///1:folder/")
            assert.equals(1, id)
            assert.equals("folder", name)
            assert.equals("directory", ftype)
        end)

        it("should parse indentation", function()
            local id, indent, name, ftype = parser.parse_line("///5:    nested.txt")
            assert.equals(5, id)
            assert.equals(4, indent)
            assert.equals("nested.txt", name)
        end)

        it("should handle deep indentation", function()
            local id, indent, name, ftype = parser.parse_line("///10:        deep.txt")
            assert.equals(10, id)
            assert.equals(8, indent)
            assert.equals("deep.txt", name)
        end)

        it("should parse directory without ID", function()
            local id, indent, name, ftype = parser.parse_line("    newdir/")
            assert.is_nil(id)
            assert.equals(4, indent)
            assert.equals("newdir", name)
            assert.equals("directory", ftype)
        end)

        it("should handle empty name", function()
            local id, indent, name, ftype = parser.parse_line("///1:")
            assert.equals(1, id)
            assert.equals(0, indent)
            assert.equals("", name)
        end)
    end)

    describe("parse_buffer", function()
        local bufnr

        before_each(function()
            bufnr = vim.api.nvim_create_buf(false, true)
        end)

        after_each(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        end)

        local function set_lines(lines)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        end

        it("should parse root entry", function()
            set_lines({ "///1:project/" })

            local parsed = parser.parse_buffer(bufnr, "/home/user/project")
            assert.equals(1, #parsed)
            assert.equals(1, parsed[1].id)
            assert.equals("/home/user/project", parsed[1].path)
            assert.equals("project", parsed[1].name)
            assert.equals("directory", parsed[1].type)
        end)

        it("should parse child entries with correct paths", function()
            set_lines({
                "///1:project/",
                "///2:    file.txt",
                "///3:    other.lua",
            })

            local parsed = parser.parse_buffer(bufnr, "/home/user/project")
            assert.equals(3, #parsed)
            assert.equals("/home/user/project", parsed[1].path)
            assert.equals("/home/user/project/file.txt", parsed[2].path)
            assert.equals("/home/user/project/other.lua", parsed[3].path)
        end)

        it("should handle nested directories", function()
            set_lines({
                "///1:root/",
                "///2:    src/",
                "///3:        main.lua",
                "///4:    README.md",
            })

            local parsed = parser.parse_buffer(bufnr, "/root")
            assert.equals(4, #parsed)
            assert.equals("/root", parsed[1].path)
            assert.equals("/root/src", parsed[2].path)
            assert.equals("/root/src/main.lua", parsed[3].path)
            assert.equals("/root/README.md", parsed[4].path)
        end)

        it("should handle new entries without IDs", function()
            set_lines({
                "///1:project/",
                "    newfile.txt",
            })

            local parsed = parser.parse_buffer(bufnr, "/project")
            assert.equals(2, #parsed)
            assert.is_nil(parsed[2].id)
            assert.equals("/project/newfile.txt", parsed[2].path)
            assert.equals("newfile.txt", parsed[2].name)
        end)

        it("should track line numbers", function()
            set_lines({
                "///1:root/",
                "///2:    file.txt",
                "",
                "///3:    other.txt",
            })

            local parsed = parser.parse_buffer(bufnr, "/root")
            assert.equals(3, #parsed)
            assert.equals(1, parsed[1].linenr)
            assert.equals(2, parsed[2].linenr)
            assert.equals(4, parsed[3].linenr)
        end)

        it("should skip empty lines", function()
            set_lines({
                "///1:root/",
                "",
                "///2:    file.txt",
                "",
            })

            local parsed = parser.parse_buffer(bufnr, "/root")
            assert.equals(2, #parsed)
        end)

        it("should handle flexible indentation (parent by nearest less-indented dir)", function()
            -- Entry at indent 8 should attach to nearest dir with less indent
            set_lines({
                "///1:root/",
                "///2:    parent/",
                "///3:            deep.txt",  -- 12 spaces, should be under parent/
            })

            local parsed = parser.parse_buffer(bufnr, "/root")
            assert.equals(3, #parsed)
            assert.equals("/root/parent/deep.txt", parsed[3].path)
        end)

        it("should allow renaming root", function()
            set_lines({
                "///1:renamed/",  -- was "project", now "renamed"
            })

            local parsed = parser.parse_buffer(bufnr, "/home/user/project")
            assert.equals(1, #parsed)
            assert.equals("/home/user/renamed", parsed[1].path)
            assert.equals("renamed", parsed[1].name)
        end)

        it("should handle root at filesystem root", function()
            set_lines({
                "///1:etc/",
                "///2:    hosts",
            })

            local parsed = parser.parse_buffer(bufnr, "/etc")
            assert.equals(2, #parsed)
            assert.equals("/etc", parsed[1].path)
            assert.equals("/etc/hosts", parsed[2].path)
        end)

        it("should handle moving entry via indent change", function()
            -- file.txt moved from root to subdir by adding indent
            set_lines({
                "///1:root/",
                "///2:    subdir/",
                "///3:        file.txt",  -- was at root level, now under subdir
            })

            local parsed = parser.parse_buffer(bufnr, "/root")
            assert.equals("/root/subdir/file.txt", parsed[3].path)
        end)

        it("should handle multiple siblings at same level", function()
            set_lines({
                "///1:root/",
                "///2:    a.txt",
                "///3:    b.txt",
                "///4:    c.txt",
            })

            local parsed = parser.parse_buffer(bufnr, "/root")
            assert.equals(4, #parsed)
            assert.equals("/root/a.txt", parsed[2].path)
            assert.equals("/root/b.txt", parsed[3].path)
            assert.equals("/root/c.txt", parsed[4].path)
        end)

        it("should handle returning to parent level after nested", function()
            set_lines({
                "///1:root/",
                "///2:    dir1/",
                "///3:        nested.txt",
                "///4:    dir2/",  -- back to same level as dir1
            })

            local parsed = parser.parse_buffer(bufnr, "/root")
            assert.equals("/root/dir1", parsed[2].path)
            assert.equals("/root/dir1/nested.txt", parsed[3].path)
            assert.equals("/root/dir2", parsed[4].path)
        end)
    end)
end)

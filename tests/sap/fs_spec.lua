-- Run with: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/sap/fs_spec.lua"

describe("sap.fs", function()
    local fs = require("sap.fs")
    local test_dir

    local function setup_test_dir()
        local tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
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

    describe("basename", function()
        it("should return filename from path", function()
            assert.equals("file.txt", fs.basename("/foo/bar/file.txt"))
        end)

        it("should return directory name from path", function()
            assert.equals("bar", fs.basename("/foo/bar"))
        end)

        it("should handle trailing slash", function()
            -- Note: vim.fs.basename returns empty string for trailing slash
            assert.equals("", fs.basename("/foo/bar/"))
        end)
    end)

    describe("stat", function()
        it("should return stat for existing file", function()
            local path = test_dir .. "/file.txt"
            vim.fn.writefile({ "content" }, path)

            local stat = fs.stat(path)
            assert.is_not_nil(stat)
            assert.equals("file", stat.type)
        end)

        it("should return stat for existing directory", function()
            local path = test_dir .. "/subdir"
            vim.fn.mkdir(path)

            local stat = fs.stat(path)
            assert.is_not_nil(stat)
            assert.equals("directory", stat.type)
        end)

        it("should return nil for non-existent path", function()
            local stat = fs.stat(test_dir .. "/nonexistent")
            assert.is_nil(stat)
        end)

        it("should return stat for symlink without following", function()
            local target = test_dir .. "/target.txt"
            local link = test_dir .. "/link.txt"
            vim.fn.writefile({ "content" }, target)
            vim.uv.fs_symlink(target, link)

            local stat = fs.stat(link)
            assert.is_not_nil(stat)
            assert.equals("link", stat.type)
        end)
    end)

    describe("read_dir", function()
        it("should return entries for a valid directory", function()
            vim.fn.writefile({}, test_dir .. "/file1.txt")
            vim.fn.writefile({}, test_dir .. "/file2.txt")
            vim.fn.mkdir(test_dir .. "/subdir")

            local entries, err = fs.read_dir(test_dir)
            assert.is_nil(err)
            assert.is_not_nil(entries)
            assert.equals(3, #entries)
        end)

        it("should return correct entry structure", function()
            vim.fn.writefile({}, test_dir .. "/test.txt")

            local entries = fs.read_dir(test_dir)
            assert.equals(1, #entries)
            assert.equals("test.txt", entries[1].name)
            assert.equals(test_dir .. "/test.txt", entries[1].path)
            assert.equals("file", entries[1].type)
        end)

        it("should return error for non-existent directory", function()
            local entries, err = fs.read_dir(test_dir .. "/nonexistent")
            assert.is_nil(entries)
            assert.is_not_nil(err)
        end)

        it("should return empty table for empty directory", function()
            local entries = fs.read_dir(test_dir)
            assert.is_not_nil(entries)
            assert.equals(0, #entries)
        end)
    end)

    describe("create", function()
        it("should create a file", function()
            local path = test_dir .. "/newfile.txt"
            local ok, err = fs.create(path, false)

            assert.is_true(ok)
            assert.is_nil(err)
            assert.equals(1, vim.fn.filereadable(path))
        end)

        it("should create a directory", function()
            local path = test_dir .. "/newdir"
            local ok, err = fs.create(path, true)

            assert.is_true(ok)
            assert.is_nil(err)
            assert.equals(1, vim.fn.isdirectory(path))
        end)

        it("should fail to create file in non-existent directory", function()
            local path = test_dir .. "/nonexistent/file.txt"
            local ok, err = fs.create(path, false)

            assert.is_nil(ok)
            assert.is_not_nil(err)
        end)
    end)

    describe("remove", function()
        it("should remove a file", function()
            local path = test_dir .. "/file.txt"
            vim.fn.writefile({}, path)

            local ok, err = fs.remove(path)
            assert.is_true(ok)
            assert.is_nil(err)
            assert.equals(0, vim.fn.filereadable(path))
        end)

        it("should remove an empty directory", function()
            local path = test_dir .. "/emptydir"
            vim.fn.mkdir(path)

            local ok, err = fs.remove(path)
            assert.is_true(ok)
            assert.is_nil(err)
            assert.equals(0, vim.fn.isdirectory(path))
        end)

        it("should remove directory recursively", function()
            local dir = test_dir .. "/parent"
            vim.fn.mkdir(dir .. "/child", "p")
            vim.fn.writefile({}, dir .. "/file.txt")
            vim.fn.writefile({}, dir .. "/child/nested.txt")

            local ok, err = fs.remove(dir)
            assert.is_true(ok)
            assert.is_nil(err)
            assert.equals(0, vim.fn.isdirectory(dir))
        end)

        it("should return error for non-existent path", function()
            local ok, err = fs.remove(test_dir .. "/nonexistent")
            assert.is_nil(ok)
            assert.is_not_nil(err)
        end)
    end)

    describe("move", function()
        it("should rename a file", function()
            local old = test_dir .. "/old.txt"
            local new = test_dir .. "/new.txt"
            vim.fn.writefile({ "content" }, old)

            local ok, err = fs.move(old, new)
            assert.is_truthy(ok)
            assert.equals(0, vim.fn.filereadable(old))
            assert.equals(1, vim.fn.filereadable(new))
        end)

        it("should move a file to different directory", function()
            local subdir = test_dir .. "/subdir"
            vim.fn.mkdir(subdir)
            local old = test_dir .. "/file.txt"
            local new = subdir .. "/file.txt"
            vim.fn.writefile({ "content" }, old)

            local ok, err = fs.move(old, new)
            assert.is_truthy(ok)
            assert.equals(0, vim.fn.filereadable(old))
            assert.equals(1, vim.fn.filereadable(new))
        end)

        it("should rename a directory", function()
            local old = test_dir .. "/olddir"
            local new = test_dir .. "/newdir"
            vim.fn.mkdir(old)
            vim.fn.writefile({}, old .. "/file.txt")

            local ok, err = fs.move(old, new)
            assert.is_truthy(ok)
            assert.equals(0, vim.fn.isdirectory(old))
            assert.equals(1, vim.fn.isdirectory(new))
            assert.equals(1, vim.fn.filereadable(new .. "/file.txt"))
        end)
    end)

    describe("copy", function()
        it("should copy a file", function()
            local src = test_dir .. "/source.txt"
            local dst = test_dir .. "/dest.txt"
            vim.fn.writefile({ "content" }, src)

            local ok, err = fs.copy(src, dst)
            assert.is_true(ok)
            assert.is_nil(err)
            assert.equals(1, vim.fn.filereadable(src))
            assert.equals(1, vim.fn.filereadable(dst))
        end)

        it("should preserve file content", function()
            local src = test_dir .. "/source.txt"
            local dst = test_dir .. "/dest.txt"
            vim.fn.writefile({ "line1", "line2" }, src)

            fs.copy(src, dst)
            local content = vim.fn.readfile(dst)
            assert.equals(2, #content)
            assert.equals("line1", content[1])
            assert.equals("line2", content[2])
        end)

        it("should copy a directory recursively", function()
            local src = test_dir .. "/srcdir"
            local dst = test_dir .. "/dstdir"
            vim.fn.mkdir(src .. "/child", "p")
            vim.fn.writefile({}, src .. "/file.txt")
            vim.fn.writefile({}, src .. "/child/nested.txt")

            local ok, err = fs.copy(src, dst)
            assert.is_true(ok)
            assert.is_nil(err)
            assert.equals(1, vim.fn.isdirectory(dst))
            assert.equals(1, vim.fn.isdirectory(dst .. "/child"))
            assert.equals(1, vim.fn.filereadable(dst .. "/file.txt"))
            assert.equals(1, vim.fn.filereadable(dst .. "/child/nested.txt"))
        end)

        -- NOTE: fs.copy currently uses fs_stat (follows symlinks) instead of fs_lstat,
        -- so symlinks are copied as regular files. This test documents current behavior.
        -- TODO: Fix fs.copy to use fs_lstat to preserve symlinks
        it("should copy symlink target content (current behavior)", function()
            local target = test_dir .. "/target.txt"
            local link = test_dir .. "/link.txt"
            local dst = test_dir .. "/copied_link.txt"
            vim.fn.writefile({ "content" }, target)
            vim.uv.fs_symlink(target, link)

            local ok, err = fs.copy(link, dst)
            assert.is_true(ok)
            assert.is_nil(err)

            -- Currently copies as file (follows symlink)
            local stat = fs.stat(dst)
            assert.equals("file", stat.type)

            -- Content is preserved
            local content = vim.fn.readfile(dst)
            assert.equals("content", content[1])
        end)

        it("should return error for non-existent source", function()
            local ok, err = fs.copy(test_dir .. "/nonexistent", test_dir .. "/dest")
            assert.is_nil(ok)
            assert.is_not_nil(err)
        end)
    end)
end)

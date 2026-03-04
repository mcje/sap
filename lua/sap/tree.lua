local fs = require("sap.fs")

---@class Tree
---@field name string
---@field path string
---@field stat uv.fs_stat.result
---@field hidden boolean
---@field expanded boolean
---@field sort fun(paths: string[])
---@field children table<string, Tree>?
local Tree = {}
Tree.__index = Tree

---@param path string
---@return Tree? tree
---@return string? error
Tree.new = function(path)
    local self = setmetatable({}, Tree)
    path = vim.fn.expand(path) -- ensure we have abs path
    path = vim.fn.fnamemodify(vim.fn.expand(path), ":p"):gsub("/$", "") -- strip trailing /
    self.name = fs.basename(path)
    self.path = path
    local stat = fs.stat(path)
    if stat then
        self.stat = stat
    else
        return nil, "Path invalid"
    end
    if self.name:match("^%.") then
        self.hidden = true
    else
        self.hidden = false
    end
    self.expanded = false

    self.children = nil
    return self
end

---@param self Tree
---@return boolean?
---@return string?
Tree.sync = function(self)
    local files = fs.read_dir(self.path, true)
    local current = {}
    if not self.children then
        self.children = {}
    end
    for _, file in ipairs(files) do
        local fpath = file.path
        local ftype = file.type
        current[fpath] = true
        local child = self.children[fpath] ---@type Tree?

        if child and child.stat.type ~= ftype then
            self.children[fpath] = nil
            child = nil
        end
        if self.expanded and child and ftype == "directory" then
            local ok, err = child:sync()
            if not ok then
                return nil, err
            end
        elseif not child then
            local nchild, err = Tree.new(fpath, self.sort)
            if nchild then
                self.children[fpath] = nchild
            else
                return nil, err
            end
        end
    end
    for path, _ in pairs(self.children) do
        if not current[path] then
            self.children[path] = nil
        end
    end
    return true
end

---@class FlatEntry
---@field node Tree
---@field depth integer

---@param self Tree
---@return FlatEntry[]?
---@return string?
Tree.flatten = function(self)
    local entries = {}
    local ok, err = self:_flatten(entries, 0)
    if not ok then
        return nil, err
    end
    return entries
end

---@param self Tree
---@param entries FlatEntry[]?
---@param depth integer?
---@return boolean? flatentries
---@return string? error
Tree._flatten = function(self, entries, depth)
    if not depth then
        depth = 0
    end
    if not entries then
        entries = {}
    end
    entries[#entries + 1] = { node = self, depth = depth }

    if self.expanded and self.children then
        local paths = vim.tbl_keys(self.children)
        self.sort(paths)
        for _, path in ipairs(paths) do
            local ok, err = self.children[path]:_flatten(entries, depth + 1)
            if not ok then
                return nil, err
            end
        end
    end
    return true
end

---@param self Tree
---@return boolean
Tree.is_exec = function(self)
    return bit.band(self.stat.mode, tonumber("111", 8)) ~= 0
end

return Tree

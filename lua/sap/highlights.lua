local M = {}

M.groups = {
    SapDirectory = { link = "Directory" },
    SapFile = { link = "Normal" },
    SapSymlink = { link = "Constant" },
    SapHidden = { link = "Comment" },
}

M.setup = function()
    for name, opts in pairs(M.groups) do
        vim.api.nvim_set_hl(0, name, opts)
    end
end

return M

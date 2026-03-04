local M = {}

M.defaults = {
    -- Show hidden files by default
    show_hidden = false,
    -- Icons (set to false to disable)
    icons = {
        use_devicons = true,
        directory = "",
        file = "",
    },
    -- Keymaps (set to false to disable)
    keys = {
        { "<CR>", "<cmd>Sap open<cr>", desc = "Open file/toggle dir" },
        { "<BS>", "<cmd>Sap parent<cr>", desc = "Go to parent" },
        { "<C-CR>", "<cmd>Sap set_root<cr>", desc = "Set as root" },
        { "R", "<cmd>Sap refresh<cr>", desc = "Refresh" },
        { "q", "<cmd>Sap quit<cr>", desc = "Close" },
        { ".", "<cmd>Sap toggle_hidden<cr>", desc = "Toggle hidden" },
        { ">>", "<cmd>Sap indent<cr>", desc = "Indent" },
        { "<<", "<cmd>Sap unindent<cr>", desc = "Unindent" },
        { ">", "<cmd>Sap indent<cr>", mode = "v", desc = "Indent" },
        { "<", "<cmd>Sap unindent<cr>", mode = "v", desc = "Unindent" },
    },
}

M.options = M.defaults

M.setup = function(opts)
    M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

return M

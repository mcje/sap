local M = {}

-- Use Nerd Font icons if devicons is available, otherwise unicode fallbacks
local has_devicons = pcall(require, "nvim-web-devicons")

M.defaults = {
    show_hidden = false,
    indent_size = 4,

    -- "view" = save current view only, "global" = include all cached content
    save_scope = "global",

    -- "trash" = move to trash_dir, "permanent" = delete permanently
    delete_method = "trash",
    trash_dir = vim.fn.stdpath("data") .. "/sap/trash",

    icons = {
        use_devicons = true,
        directory = "",
        file = "",
    },

    -- Tree guide lines (set to false to disable)
    guides = {
        enabled = true,
        icons = {
            expanded = has_devicons and "" or "▼",
            collapsed = has_devicons and "" or "▶",
            middle = "├", -- middle child
            last = "└", -- last child
            pipe = "│", -- vertical connector
            space = " ", -- empty space (no connector)
        },
    },

    -- Picker mode configuration (for file dialog usage)
    picker = {
        mark_hl = "WarningMsg",  -- Highlight group for mark indicator
        keymaps = {
            { "<Space>", function() require("sap.picker").toggle_mark() end, desc = "Toggle mark" },
            { "<Tab>", function() require("sap.picker").toggle_mark_down() end, desc = "Mark and move down" },
            { "<CR>", function() require("sap.picker").confirm() end, desc = "Confirm selection" },
            { "<Esc>", function() require("sap.picker").cancel() end, desc = "Cancel" },
            { "q", function() require("sap.picker").cancel() end, desc = "Cancel" },
            -- Navigation keymaps (call actions directly)
            { "<BS>", function() require("sap.actions").parent() end, desc = "Go to parent" },
            { "l", function() require("sap.actions").expand() end, desc = "Expand directory" },
            { "h", function() require("sap.actions").collapse() end, desc = "Collapse directory" },
            { ".", function() require("sap.actions").toggle_hidden() end, desc = "Toggle hidden" },
        },
    },

    -- Buffer-local keymaps (set to false to disable all)
    buffer_keymaps = {
        { "<CR>", "<cmd>Sap open<cr>", desc = "Open file / toggle dir" },
        { "<BS>", "<cmd>Sap parent<cr>", desc = "Go to parent" },
        { "<C-CR>", "<cmd>Sap set_root<cr>", desc = "Set as root" },
        { "R", "<cmd>Sap refresh<cr>", desc = "Refresh" },
        { "q", "<cmd>Sap quit<cr>", desc = "Close" },
        { ".", "<cmd>Sap toggle_hidden<cr>", desc = "Toggle hidden" },
        { "l", "<cmd>Sap expand<cr>", desc = "Expand directory" },
        { "h", "<cmd>Sap collapse<cr>", desc = "Collapse directory" },
        { ">>", "<cmd>Sap indent<cr>", desc = "Indent" },
        { "<<", "<cmd>Sap unindent<cr>", desc = "Unindent" },
        { ">", "<cmd>Sap indent<cr>", mode = "v", desc = "Indent" },
        { "<", "<cmd>Sap unindent<cr>", mode = "v", desc = "Unindent" },
        { "p", "<cmd>Sap paste<cr>", desc = "Smart paste" },
        { "P", "<cmd>Sap paste_before<cr>", desc = "Smart paste before" },
    },
}

M.options = vim.deepcopy(M.defaults)

---@param opts table?
M.setup = function(opts)
    M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

return M

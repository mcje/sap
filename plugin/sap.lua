if vim.g.loaded_sap then
    return
end
vim.g.loaded_sap = true

vim.api.nvim_create_user_command("Sap", function(opts)
    local path = opts.args ~= "" and opts.args or nil
    require("sap").open(path)
end, {
    nargs = "?",
    complete = "dir",
    desc = "Open sap file browser",
})

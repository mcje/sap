-- Minimal init for running tests
-- Usage: nvim --headless -u tests/sap/minimal_init.lua -c "PlenaryBustedDirectory tests/sap"

vim.opt.runtimepath:append(".")
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")

vim.cmd.runtime("plugin/plenary.vim")

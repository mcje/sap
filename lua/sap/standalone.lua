-- Standalone mode for sap file manager/picker
-- Opens files externally, disables nvim editing, for use as desktop file manager

local M = {}

function M.enable()
    -- Prevent opening other files
    vim.api.nvim_create_autocmd("BufReadCmd", {
        pattern = "*",
        callback = function(ev)
            -- Allow sap buffers
            if ev.file:match("^sap://") or ev.file:match("^sap%-picker://") then
                return
            end
            -- Prevent opening regular files
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(ev.buf) then
                    vim.api.nvim_buf_delete(ev.buf, { force = true })
                end
            end)
            vim.notify("File editing disabled in standalone mode", vim.log.levels.WARN)
            return true
        end,
    })

    -- Disable some commands via abbreviations
    vim.cmd([[
        cabbrev e <nop>
        cabbrev edit <nop>
        cabbrev tabedit <nop>
        cabbrev tabe <nop>
        cabbrev new <nop>
        cabbrev vnew <nop>
        cabbrev split <nop>
        cabbrev vsplit <nop>
        cabbrev sp <nop>
        cabbrev vs <nop>
    ]])

    -- Clean up UI a bit
    vim.opt.laststatus = 0
    vim.opt.showtabline = 0

    -- Remap <CR> to open files externally (directories still toggle)
    vim.api.nvim_create_autocmd("BufEnter", {
        pattern = "sap://*",
        callback = function(ev)
            vim.keymap.set("n", "<CR>", function()
                local actions = require("sap.actions")
                local buffer = require("sap.buffer")
                local entry = buffer.get_entry_at_line(ev.buf, vim.api.nvim_win_get_cursor(0)[1])
                if entry and entry.type == "file" then
                    actions.open_external()
                else
                    actions.open()
                end
            end, { buffer = ev.buf, desc = "Open external / toggle dir" })
        end,
    })
end

return M

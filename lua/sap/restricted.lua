-- Restricted mode for sap file manager/picker
-- Disables file editing and some commands while keeping user config

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
            vim.notify("File editing disabled in picker mode", vim.log.levels.WARN)
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
end

return M

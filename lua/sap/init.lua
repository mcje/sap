local config = require("sap.config")
local actions = require("sap.actions")
local buffer = require("sap.buffer")

local M = {}

M.setup = function(opts)
    config.setup(opts)
end

M.open = function(path, opts)
    path = path or vim.fn.getcwd()
    opts = opts or {}
    local bufnr, err = require("sap.buffer").create(path)
    if not bufnr then
        vim.notify("sap: " .. err, vim.log.levels.ERROR)
        return
    end

    -- Buffer commands
    vim.api.nvim_buf_create_user_command(bufnr, "Sap", function(cmd_opts)
        local cmd = cmd_opts.fargs[1]
        if cmd == "open" then
            actions.open()
        elseif cmd == "parent" then
            actions.parent()
        elseif cmd == "set_root" then
            actions.set_root()
        elseif cmd == "refresh" then
            actions.refresh()
        elseif cmd == "quit" then
            if opts.quit_on_close then
                vim.cmd("qa!")
            else
                buffer.close(bufnr)
            end
        elseif cmd == "toggle_hidden" then
            actions.toggle_hidden()
        elseif cmd == "expand" then
            actions.expand()
        elseif cmd == "collapse" then
            actions.collapse()
        elseif cmd == "indent" then
            actions.indent(cmd_opts.range > 0)()
        elseif cmd == "unindent" then
            actions.unindent(cmd_opts.range > 0)()
        elseif cmd == "paste" then
            actions.paste()
        elseif cmd == "paste_before" then
            actions.paste_before()
        elseif cmd == "open_external" then
            actions.open_external()
        elseif cmd == "preview" then
            require("sap.preview").toggle()
        end
    end, { nargs = 1, range = true })

    -- Set keymaps
    if config.options.buffer_keymaps then
        for _, km in ipairs(config.options.buffer_keymaps) do
            local mode = km.mode or "n"
            vim.keymap.set(mode, km[1], km[2], { buffer = bufnr, desc = km.desc })
        end
    end

    vim.api.nvim_set_current_buf(bufnr)

    -- Auto-open preview if requested
    if opts.preview then
        -- Override position if specified
        if type(opts.preview) == "string" then
            config.options.preview = config.options.preview or {}
            config.options.preview.position = opts.preview
        end
        vim.schedule(function()
            require("sap.preview").open()
        end)
    end
end

return M

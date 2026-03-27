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

-- File picker command (for terminal/GUI file dialog usage)
vim.api.nvim_create_user_command("SapPick", function(opts)
    local args = {}
    local positional = {}

    -- Parse arguments
    for _, arg in ipairs(opts.fargs) do
        local key, value = arg:match("^%-%-([%w_]+)=(.+)$")
        if key then
            args[key] = value
        elseif arg:match("^%-%-([%w_]+)$") then
            args[arg:match("^%-%-([%w_]+)$")] = true
        else
            positional[#positional + 1] = arg
        end
    end

    local cmd = positional[1]
    local picker = require("sap.picker")

    -- Subcommands (actions within picker)
    if cmd == "mark" then
        picker.toggle_mark()
    elseif cmd == "mark_down" then
        picker.toggle_mark_down()
    elseif cmd == "confirm" then
        picker.confirm()
    elseif cmd == "cancel" then
        picker.cancel()
    else
        -- Open picker with mode
        picker.open({
            mode = cmd or "open",
            multiple = args.multiple == true,
            output_file = args.output,
            initial_path = args.path,
            quit_on_confirm = args.output ~= nil,
            register = args.reg,  -- true or specific register name
            notify = args.notify == true,
        })
    end
end, {
    nargs = "*",
    complete = function(arglead, cmdline, cursorpos)
        if cmdline:match("^SapPick%s+$") or cmdline:match("^SapPick%s+[^-]%S*$") then
            return { "open", "open_dir", "save", "mark", "mark_down", "confirm", "cancel" }
        end
        if arglead:match("^%-") then
            return { "--multiple", "--output=", "--path=", "--reg", "--reg=", "--notify" }
        end
        return {}
    end,
    desc = "Sap file picker (for file dialogs)",
})

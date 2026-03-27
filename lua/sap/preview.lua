local buffer = require("sap.buffer")
local config = require("sap.config")

local M = {}

-- Preview state
local preview_win = nil
local preview_buf = nil
local preview_enabled = false
local autocmd_id = nil
local current_image_path = nil  -- Track if we're showing an image

-- Check for kitty terminal
local is_kitty = vim.env.TERM == "xterm-kitty" or vim.env.KITTY_WINDOW_ID ~= nil

-- Check for snacks.nvim image support
local has_snacks, snacks = pcall(require, "snacks")
local snacks_image_supported = has_snacks and snacks.image and snacks.image.supports_terminal and snacks.image.supports_terminal()

-- Image file extensions
local image_extensions = {
    png = true, jpg = true, jpeg = true, gif = true, webp = true,
    bmp = true, tiff = true, tif = true, svg = true, ico = true,
}

--- Check if file is an image by extension
---@param path string
---@return boolean
local function is_image(path)
    local ext = path:match("%.([^%.]+)$")
    return ext and image_extensions[ext:lower()] or false
end

-- Magic bytes for image formats
local image_magic = {
    { "\x89PNG\r\n\x1a\n", "png" },
    { "\xff\xd8\xff", "jpg" },
    { "GIF87a", "gif" },
    { "GIF89a", "gif" },
    { "RIFF", "webp" },  -- WebP starts with RIFF
    { "BM", "bmp" },
}

--- Validate image file by checking magic bytes
---@param path string
---@return boolean
local function is_valid_image(path)
    local fd = vim.loop.fs_open(path, "r", 438)
    if not fd then
        return false
    end

    local header = vim.loop.fs_read(fd, 16, 0)
    vim.loop.fs_close(fd)

    if not header or #header < 2 then
        return false
    end

    for _, magic in ipairs(image_magic) do
        if header:sub(1, #magic[1]) == magic[1] then
            return true
        end
    end

    -- Check for WebP (RIFF....WEBP)
    if header:sub(1, 4) == "RIFF" and header:sub(9, 12) == "WEBP" then
        return true
    end

    return false
end

-- Track snacks image placement
local current_snacks_image = nil

--- Clear image placement
local function clear_image()
    if current_snacks_image then
        pcall(function() current_snacks_image:close() end)
        current_snacks_image = nil
    end
    current_image_path = nil
end

--- Display image using snacks.nvim
---@param path string
---@param win integer
local function show_kitty_image(path, win)
    if not snacks_image_supported then
        return false
    end

    -- Get absolute path
    local abs_path = vim.fn.fnamemodify(path, ":p")

    -- Validate image before passing to snacks
    if not is_valid_image(abs_path) then
        return false
    end

    -- Get window size for the image
    local win_width = vim.api.nvim_win_get_width(win)
    local win_height = vim.api.nvim_win_get_height(win)

    -- Create placement directly (handles image internally)
    local ok, result = pcall(function()
        local Placement = require("snacks.image.placement")

        local placement = Placement.new(preview_buf, abs_path, {
            pos = { 1, 0 },
            max_width = win_width,
            max_height = win_height - 2,
            inline = true,
        })

        if placement then
            placement:show()
        end

        return placement
    end)

    if ok and result then
        current_snacks_image = result
        current_image_path = path
        return true
    end

    return false
end

--- Get preview config with defaults
local function get_config()
    local cfg = config.options.preview or {}
    return {
        position = cfg.position or "float", -- "float", "right", "bottom"
        width = cfg.width or 0.5,  -- fraction of editor width (for right split/float)
        height = cfg.height or 0.8, -- fraction of editor height (for bottom split/float)
        max_lines = cfg.max_lines or 500, -- don't preview files larger than this
        max_size = cfg.max_size or 100000, -- don't preview files larger than 100KB
    }
end

--- Check if file is previewable (text file, not too large)
---@param path string
---@return boolean ok
---@return string? reason
local function is_previewable(path)
    local stat = vim.loop.fs_stat(path)
    if not stat then
        return false, "Cannot stat file"
    end

    if stat.type == "directory" then
        return false, "Directory"
    end

    local cfg = get_config()
    if stat.size > cfg.max_size then
        return false, string.format("File too large (%d bytes)", stat.size)
    end

    -- Check if binary by reading first chunk
    local fd = vim.loop.fs_open(path, "r", 438)
    if not fd then
        return false, "Cannot open file"
    end

    local chunk = vim.loop.fs_read(fd, 1024, 0)
    vim.loop.fs_close(fd)

    if chunk and chunk:find("\0") then
        return false, "Binary file"
    end

    return true
end

--- Create or get preview buffer
local function get_preview_buf()
    if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
        return preview_buf
    end

    preview_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[preview_buf].bufhidden = "wipe"
    vim.bo[preview_buf].buftype = "nofile"
    vim.bo[preview_buf].swapfile = false
    return preview_buf
end

--- Create preview window
local function create_preview_win()
    local cfg = get_config()
    local buf = get_preview_buf()

    if cfg.position == "float" then
        -- Position float to the right of current window
        local win_width = vim.api.nvim_win_get_width(0)
        local win_height = vim.api.nvim_win_get_height(0)
        local win_pos = vim.api.nvim_win_get_position(0)

        local width = math.floor(win_width * 0.5)
        local height = math.floor(win_height * 0.95)
        local row = win_pos[1] + math.floor((win_height - height) / 2)
        local col = win_pos[2] + win_width + 1  -- Right of current window

        -- Clamp to editor bounds (account for cmdheight and status)
        local max_height = vim.o.lines - vim.o.cmdheight - 2
        if row + height > max_height then
            height = max_height - row
        end
        if col + width > vim.o.columns then
            col = vim.o.columns - width - 1
        end

        preview_win = vim.api.nvim_open_win(buf, false, {
            relative = "editor",
            width = width,
            height = height,
            row = row,
            col = col,
            style = "minimal",
            border = "rounded",
            title = " Preview ",
            title_pos = "center",
        })
    elseif cfg.position == "right" then
        local width = math.floor(vim.o.columns * cfg.width)
        vim.cmd("vertical rightbelow " .. width .. "split")
        preview_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(preview_win, buf)
        -- Return focus to sap buffer
        vim.cmd("wincmd p")
    elseif cfg.position == "bottom" then
        local height = math.floor(vim.o.lines * cfg.height)
        vim.cmd("rightbelow " .. height .. "split")
        preview_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(preview_win, buf)
        -- Return focus to sap buffer
        vim.cmd("wincmd p")
    end

    -- Set preview window options
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
        vim.wo[preview_win].number = true
        vim.wo[preview_win].relativenumber = false
        vim.wo[preview_win].wrap = false
        vim.wo[preview_win].cursorline = true
    end

    return preview_win
end

--- Update preview content for given path
---@param path string
local function show_preview(path)
    if not preview_win or not vim.api.nvim_win_is_valid(preview_win) then
        create_preview_win()
    end

    if not preview_buf or not vim.api.nvim_buf_is_valid(preview_buf) then
        preview_buf = get_preview_buf()
        if preview_win and vim.api.nvim_win_is_valid(preview_win) then
            vim.api.nvim_win_set_buf(preview_win, preview_buf)
        end
    end

    -- Clear any previous image
    clear_image()

    -- Handle image files with kitty icat
    if is_image(path) then
        -- Clear buffer content
        vim.bo[preview_buf].modifiable = true
        vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, {})
        vim.bo[preview_buf].modifiable = false
        vim.bo[preview_buf].filetype = ""

        -- Disable line numbers and cursorline for cleaner image display
        vim.wo[preview_win].number = false
        vim.wo[preview_win].signcolumn = "no"
        vim.wo[preview_win].cursorline = false

        if snacks_image_supported then
            show_kitty_image(path, preview_win)
        else
            -- No image support, show message
            vim.bo[preview_buf].modifiable = true
            vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, {
                "",
                "  Image file",
                "  (requires snacks.nvim with image support)",
                "",
            })
            vim.bo[preview_buf].modifiable = false
        end

        -- Update window title
        local cfg = get_config()
        if cfg.position == "float" and preview_win and vim.api.nvim_win_is_valid(preview_win) then
            local name = vim.fn.fnamemodify(path, ":t")
            vim.api.nvim_win_set_config(preview_win, {
                title = " " .. name .. " ",
                title_pos = "center",
            })
        end
        return
    end

    -- Re-enable line numbers and cursorline for text files
    vim.wo[preview_win].number = true
    vim.wo[preview_win].signcolumn = "no"
    vim.wo[preview_win].cursorline = true

    local ok, reason = is_previewable(path)
    local lines

    if not ok then
        lines = { "", "  " .. reason, "" }
    else
        local cfg = get_config()
        local content = vim.fn.readfile(path, "", cfg.max_lines)
        if #content == cfg.max_lines then
            table.insert(content, "")
            table.insert(content, "... (truncated)")
        end
        lines = content
    end

    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
    vim.bo[preview_buf].modifiable = false

    -- Set filetype for syntax highlighting
    if ok then
        local ft = vim.filetype.match({ filename = path })
        if ft then
            vim.bo[preview_buf].filetype = ft
        end
    end

    -- Update window title for float
    local cfg = get_config()
    if cfg.position == "float" and preview_win and vim.api.nvim_win_is_valid(preview_win) then
        local name = vim.fn.fnamemodify(path, ":t")
        vim.api.nvim_win_set_config(preview_win, {
            title = " " .. name .. " ",
            title_pos = "center",
        })
    end
end

--- Update preview for current cursor position
function M.update()
    if not preview_enabled then
        return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local linenr = vim.api.nvim_win_get_cursor(0)[1]
    local entry = buffer.get_entry_at_line(bufnr, linenr)

    if entry and entry.type == "file" then
        show_preview(entry.path)
    elseif entry and entry.type == "directory" then
        -- Clear any image first
        clear_image()

        -- Restore window options
        vim.wo[preview_win].number = false
        vim.wo[preview_win].cursorline = false

        -- Show directory info
        if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
            local items = vim.fn.readdir(entry.path)
            local lines = {
                "  Directory: " .. entry.path,
                "  Items: " .. #items,
            }
            vim.bo[preview_buf].modifiable = true
            vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
            vim.bo[preview_buf].modifiable = false
            vim.bo[preview_buf].filetype = ""
        end
    else
        -- No entry or unknown type, clear image
        clear_image()
    end
end

--- Close preview window
function M.close()
    -- Clear any image first
    clear_image()

    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
        vim.api.nvim_win_close(preview_win, true)
    end
    preview_win = nil

    if autocmd_id then
        vim.api.nvim_del_autocmd(autocmd_id)
        autocmd_id = nil
    end

    preview_enabled = false
end

--- Toggle preview on/off
function M.toggle()
    if preview_enabled then
        M.close()
    else
        M.open()
    end
end

--- Open preview (enables auto-update)
function M.open()
    preview_enabled = true

    -- Create window and show initial preview
    create_preview_win()
    M.update()

    -- Set up auto-update on cursor move
    local bufnr = vim.api.nvim_get_current_buf()
    autocmd_id = vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = bufnr,
        callback = function()
            M.update()
        end,
    })

    -- Close preview when leaving sap buffer
    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = bufnr,
        once = true,
        callback = function()
            M.close()
        end,
    })
end

--- Check if preview is currently open
---@return boolean
function M.is_open()
    return preview_enabled and preview_win ~= nil and vim.api.nvim_win_is_valid(preview_win)
end

--- Scroll preview window
---@param direction "up"|"down"
function M.scroll(direction)
    if not M.is_open() then
        return
    end

    local cmd = direction == "down" and "\\<C-d>" or "\\<C-u>"
    vim.api.nvim_win_call(preview_win, function()
        vim.cmd("normal! " .. vim.api.nvim_replace_termcodes(cmd, true, false, true))
    end)
end

--- Set up preview keymaps on buffer
---@param bufnr integer
local function setup_keymaps(bufnr)
    vim.keymap.set("n", "<C-d>", function() M.scroll("down") end, { buffer = bufnr, desc = "Scroll preview down" })
    vim.keymap.set("n", "<C-u>", function() M.scroll("up") end, { buffer = bufnr, desc = "Scroll preview up" })
end

--- Remove preview keymaps from buffer
---@param bufnr integer
local function remove_keymaps(bufnr)
    pcall(vim.keymap.del, "n", "<C-d>", { buffer = bufnr })
    pcall(vim.keymap.del, "n", "<C-u>", { buffer = bufnr })
end

-- Store bufnr for keymap cleanup
local keymap_bufnr = nil

-- Wrap M.open to add keymaps
local original_open = M.open
M.open = function()
    original_open()
    keymap_bufnr = vim.api.nvim_get_current_buf()
    setup_keymaps(keymap_bufnr)
end

-- Wrap M.close to remove keymaps
local original_close = M.close
M.close = function()
    if keymap_bufnr and vim.api.nvim_buf_is_valid(keymap_bufnr) then
        remove_keymaps(keymap_bufnr)
    end
    keymap_bufnr = nil
    original_close()
end

return M

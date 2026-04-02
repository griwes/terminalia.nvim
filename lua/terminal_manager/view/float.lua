local M = {}

---@param ratio number
---@param total integer
---@return integer
local function scaled_size(ratio, total)
    return math.max(10, math.floor(total * ratio))
end

---Reveal a terminal in a floating window.
---@param terminal terminal_manager.TerminalRecord
---@param cfg terminal_manager.Config
---@return integer
function M.open(terminal, cfg)
    local float_cfg = cfg.float
    local bufnr = assert(terminal.bufnr, 'terminal buffer missing')
    local width = scaled_size(float_cfg.width, vim.o.columns)
    local height = scaled_size(float_cfg.height, vim.o.lines - vim.o.cmdheight)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local winid = vim.api.nvim_open_win(bufnr, true, {
        relative = 'editor',
        row = row,
        col = col,
        width = width,
        height = height,
        style = 'minimal',
        border = float_cfg.border,
    })

    vim.cmd('startinsert')

    return winid
end

return M

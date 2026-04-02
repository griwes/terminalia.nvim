local M = {}

---Reveal a terminal in a split window.
---@param terminal terminal_manager.TerminalRecord
---@param cfg terminal_manager.Config
---@return integer
function M.open(terminal, cfg)
    local direction = cfg.split_direction or 'botright'
    local size = cfg.split_size or 12
    local bufnr = assert(terminal.bufnr, 'terminal buffer missing')

    vim.cmd(string.format('%s split', direction))
    vim.cmd(string.format('resize %d', size))
    vim.api.nvim_win_set_buf(0, bufnr)
    vim.cmd('startinsert')

    return vim.api.nvim_get_current_win()
end

return M

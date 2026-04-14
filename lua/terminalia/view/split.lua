local M = {}
local config = require('terminalia.config')

---Reveal a terminal in a split window.
---@param terminal terminalia.TerminalRecord
---@param cfg terminalia.Config
---@return integer
function M.open(terminal, cfg)
    local direction = config.normalize_split_direction(cfg.split_direction)
    local size = cfg.split_size or 12
    local bufnr = assert(terminal.bufnr, 'terminal buffer missing')

    vim.cmd(string.format('%s split', direction))
    vim.cmd(string.format('resize %d', size))
    vim.api.nvim_win_set_buf(0, bufnr)
    vim.cmd('startinsert')

    return vim.api.nvim_get_current_win()
end

return M

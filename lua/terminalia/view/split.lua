local M = {}
local config = require('terminalia.config')

---Reveal a terminal in a split window.
---@param terminal terminalia.TerminalRecord
---@param cfg terminalia.Config
---@param opts? { start_insert?: boolean }
---@return integer
function M.open(terminal, cfg, opts)
    local direction = config.normalize_split_direction(cfg.split_direction)
    local size = cfg.split_size or 12
    local bufnr = assert(terminal.bufnr, 'terminal buffer missing')

    vim.cmd(string.format('%s split', direction))
    vim.cmd(string.format('resize %d', size))
    vim.api.nvim_win_set_buf(0, bufnr)
    require('terminalia.winbar').install(bufnr)

    if opts == nil or opts.start_insert ~= false then
        vim.cmd('startinsert')
    end

    return vim.api.nvim_get_current_win()
end

return M

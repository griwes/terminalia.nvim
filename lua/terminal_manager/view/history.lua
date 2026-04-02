local M = {}

---@param terminal terminal_manager.TerminalRecord?
---@param lines string[]
---@param cfg terminal_manager.Config
---@return integer
function M.open(terminal, lines, cfg)
    local direction = cfg.split_direction or 'botright'
    local size = cfg.split_size or 12
    local name = terminal and terminal.name or 'history'
    local id = terminal and terminal.id or 'detached'

    vim.cmd(string.format('%s split', direction))
    vim.cmd(string.format('resize %d', size))

    local bufnr = vim.api.nvim_create_buf(false, true)

    vim.bo[bufnr].buftype = 'nofile'
    vim.bo[bufnr].bufhidden = 'wipe'
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].filetype = 'terminalmanagerhistory'
    vim.api.nvim_buf_set_name(bufnr, string.format('terminal-manager-history://%s/%s', id, name))
    vim.api.nvim_win_set_buf(0, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, #lines > 0 and lines or { '[no history captured]' })
    vim.bo[bufnr].modifiable = false

    return vim.api.nvim_get_current_win()
end

return M

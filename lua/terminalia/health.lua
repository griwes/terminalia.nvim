local M = {}

local function check_optional(module, label)
    if pcall(require, module) then
        vim.health.ok(label .. ' integration is available')
    else
        vim.health.info(label .. ' integration is not installed')
    end
end

function M.check()
    vim.health.start('terminalia.nvim')

    if vim.fn.has('nvim-0.11') == 1 then
        vim.health.ok('Neovim 0.11 or newer')
    else
        vim.health.error('Neovim 0.11 or newer is required')
    end

    local config = require('terminalia.config').get()
    local shell = type(config.shell) == 'table' and config.shell[1] or config.shell
    if type(shell) == 'string' and vim.fn.executable(shell) == 1 then
        vim.health.ok('Configured shell is executable: ' .. shell)
    else
        vim.health.error('Configured shell is not executable: ' .. tostring(shell))
    end

    check_optional('continuity', 'Continuity')
    check_optional('ministry', 'Ministry')
    check_optional('overseer', 'Overseer')
end

return M

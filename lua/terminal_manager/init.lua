local config = require('terminal_manager.config')
local api = require('terminal_manager.api')
local commands = require('terminal_manager.commands')
local runtime = require('terminal_manager.runtime.native')

---@class terminal_manager.RootModule
---@field config terminal_manager.Config
---@field api table

local M = {}

M.config = config.get()
M.api = api
commands.ensure(M)

---Configure terminal-manager.
---@param opts? Partial<terminal_manager.Config>
---@return terminal_manager.Config
function M.setup(opts)
    M.config = config.set(opts)
    runtime.ensure_autocmds()
    api.restore()
    return M.config
end

return M

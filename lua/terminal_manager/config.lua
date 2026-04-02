---@alias terminal_manager.ViewKind 'split'|'float'

---@class terminal_manager.FloatConfig
---@field width number
---@field height number
---@field border string

---@class terminal_manager.Config
---@field default_namespace string
---@field default_view terminal_manager.ViewKind
---@field persist_terminals boolean
---@field shell string|string[]
---@field split_direction string
---@field split_size integer
---@field float terminal_manager.FloatConfig
---@field notify_on_exit boolean

local M = {}

---@type terminal_manager.Config
local defaults = {
    default_namespace = 'default',
    default_view = 'split',
    persist_terminals = true,
    shell = vim.o.shell,
    split_direction = 'botright',
    split_size = 12,
    float = {
        width = 0.8,
        height = 0.8,
        border = 'rounded',
    },
    notify_on_exit = true,
}

---@type terminal_manager.Config
local current = vim.deepcopy(defaults)

---Normalize a user configuration table.
---@param user_opts? Partial<terminal_manager.Config>
---@return terminal_manager.Config
function M.normalize(user_opts)
    return vim.tbl_deep_extend('force', vim.deepcopy(defaults), user_opts or {})
end

---Set the active configuration.
---@param user_opts? Partial<terminal_manager.Config>
---@return terminal_manager.Config
function M.set(user_opts)
    current = M.normalize(user_opts)
    return current
end

---Get the active configuration.
---@return terminal_manager.Config
function M.get()
    return current
end

return M

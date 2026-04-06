---@alias terminal_manager.ViewKind 'split'|'float'

---@class terminal_manager.FloatConfig
---@field width number
---@field height number
---@field border string

---@class terminal_manager.Config
---@field default_namespace string
---@field default_view terminal_manager.ViewKind
---@field persist_terminals boolean
---@field persist_history boolean
---@field state_file string
---@field history_dir string
---@field shell string|string[]
---@field split_direction string
---@field split_size integer
---@field float terminal_manager.FloatConfig
---@field notify_on_exit boolean

local M = {}
local valid_views = {
    split = true,
    float = true,
}
local valid_split_directions = {
    aboveleft = true,
    belowright = true,
    botright = true,
    leftabove = true,
    rightbelow = true,
    topleft = true,
    vertical = true,
}

---@type terminal_manager.Config
local defaults = {
    default_namespace = 'default',
    default_view = 'split',
    persist_terminals = true,
    persist_history = true,
    state_file = vim.fs.joinpath(vim.fn.stdpath('state'), 'terminal-manager.nvim', 'terminals.json'),
    history_dir = vim.fs.joinpath(vim.fn.stdpath('state'), 'terminal-manager.nvim', 'history'),
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
---@param base_opts? terminal_manager.Config
---@return terminal_manager.Config
function M.normalize(user_opts, base_opts)
    local normalized = vim.tbl_deep_extend('force', vim.deepcopy(base_opts or defaults), user_opts or {})

    if not valid_views[normalized.default_view] then
        normalized.default_view = defaults.default_view
    end
    normalized.split_direction = M.normalize_split_direction(normalized.split_direction)

    return normalized
end

---Preview a configuration merged onto a base config.
---@param user_opts? Partial<terminal_manager.Config>|terminal_manager.Config
---@param base_opts? terminal_manager.Config
---@return terminal_manager.Config
function M.preview(user_opts, base_opts)
    return M.normalize(user_opts, base_opts or current)
end

---@param view? string
---@return terminal_manager.ViewKind
function M.normalize_view(view)
    if valid_views[view] then
        return view
    end

    return M.get().default_view
end

---@param direction? string
---@return string
function M.normalize_split_direction(direction)
    local value = direction or defaults.split_direction

    if valid_split_directions[value] then
        return value
    end

    return defaults.split_direction
end

---Set the active configuration.
---@param user_opts? Partial<terminal_manager.Config>
---@return terminal_manager.Config
function M.set(user_opts)
    local next_config = M.preview(user_opts, user_opts and current or defaults)

    for key in pairs(current) do
        current[key] = nil
    end

    for key, value in pairs(next_config) do
        current[key] = value
    end

    return current
end

---Get the active configuration.
---@return terminal_manager.Config
function M.get()
    return current
end

return M

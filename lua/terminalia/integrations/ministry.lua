local registry = require('terminalia.terminal.registry')

local M = {}

---@type table<string, { terminal_id?: string, context_stack?: { id: string, kind: string, label: string }[] }>
local ministry_terminal_context_bindings = {}
---@type table?
local registered_terminal_data_provider = nil
---@type table?
local registered_ministry = nil
---@type fun(id: string): { id: string, kind: string, label: string }[]|nil
local context_stack_for_bound_terminal = nil
---@type fun(): { id: string, kind: string, label: string }[]|nil
local current_context_stack = nil

---@param item table
---@return table<string, any>|nil
local function terminal_list_data_provider(item)
    if type(item) ~= 'table' or type(item.terminal_id) ~= 'string' then
        return nil
    end

    local binding = ministry_terminal_context_bindings[item.terminal_id]
    if binding == nil then
        return nil
    end

    if binding.context_stack ~= nil then
        return {
            terminalia_context_stack = vim.deepcopy(binding.context_stack),
        }
    end

    local terminal = binding.terminal_id ~= nil and registry.get(binding.terminal_id) or nil
    if terminal == nil or context_stack_for_bound_terminal == nil then
        ministry_terminal_context_bindings[item.terminal_id] = nil
        return nil
    end

    return {
        terminalia_context_stack = context_stack_for_bound_terminal(terminal.id),
    }
end

---@param context_stack_for_terminal fun(id: string): { id: string, kind: string, label: string }[]
---@return table|nil, table|nil
local function ensure_terminal_data_provider(context_stack_for_terminal)
    local ministry = assert(package.loaded.ministry or require('ministry'), 'ministry.nvim is not installed')

    if type(ministry) ~= 'table' or type(ministry.register_list_item_data_provider) ~= 'function' then
        error('ministry.nvim does not expose register_list_item_data_provider')
    end

    context_stack_for_bound_terminal = context_stack_for_terminal

    if registered_ministry == ministry and registered_terminal_data_provider ~= nil then
        return registered_terminal_data_provider, nil
    end

    local registered, register_err =
        ministry.register_list_item_data_provider('terminals', 'terminalia', terminal_list_data_provider)
    if register_err ~= nil then
        return nil, register_err
    end

    registered_ministry = ministry
    registered_terminal_data_provider = registered
    return registered, nil
end

---@param item table
local function terminal_created(item)
    if type(item) ~= 'table' or type(item.terminal_id) ~= 'string' or current_context_stack == nil then
        return
    end

    ministry_terminal_context_bindings[item.terminal_id] = {
        context_stack = vim.deepcopy(current_context_stack()),
    }
end

---@param item table
local function terminal_released(item)
    if type(item) == 'table' and type(item.terminal_id) == 'string' then
        ministry_terminal_context_bindings[item.terminal_id] = nil
    end
end

local function terminal_runtime_reset()
    ministry_terminal_context_bindings = {}
end

---@param context_stack fun(): { id: string, kind: string, label: string }[]
---@param context_stack_for_terminal fun(id: string): { id: string, kind: string, label: string }[]
---@return table|nil, table|nil
function M.setup(context_stack, context_stack_for_terminal)
    local ministry = package.loaded.ministry or require('ministry')

    if type(ministry) ~= 'table' or type(ministry.register_list_item_data_provider) ~= 'function' then
        return nil,
            {
                code = -32601,
                message = 'ministry.nvim does not expose register_list_item_data_provider',
            }
    end

    if type(ministry.register_terminal_lifecycle_listener) ~= 'function' then
        return nil,
            {
                code = -32601,
                message = 'ministry.nvim does not expose register_terminal_lifecycle_listener',
            }
    end

    current_context_stack = context_stack
    context_stack_for_bound_terminal = context_stack_for_terminal

    local list_provider, list_err =
        ministry.register_list_item_data_provider('terminals', 'terminalia', terminal_list_data_provider)
    if list_err ~= nil then
        return nil, list_err
    end

    local lifecycle_listener, lifecycle_err = ministry.register_terminal_lifecycle_listener('terminalia', {
        created = terminal_created,
        released = terminal_released,
        reset = terminal_runtime_reset,
    })
    if lifecycle_err ~= nil then
        return nil, lifecycle_err
    end

    registered_ministry = ministry
    registered_terminal_data_provider = list_provider
    return {
        list_provider = list_provider,
        lifecycle_listener = lifecycle_listener,
    }, nil
end

---@param ministry_terminal_id string
---@param terminal_id string
---@param context_stack_for_terminal fun(id: string): { id: string, kind: string, label: string }[]
---@return table|nil, table|nil
function M.attach_terminal_context(ministry_terminal_id, terminal_id, context_stack_for_terminal)
    local registered, register_err = ensure_terminal_data_provider(context_stack_for_terminal)
    if register_err ~= nil then
        return nil, register_err
    end

    assert(registry.get(terminal_id) ~= nil, string.format('Unknown terminal id: %s', terminal_id))
    ministry_terminal_context_bindings[ministry_terminal_id] = {
        terminal_id = terminal_id,
    }

    return {
        list_name = registered.list_name,
        item_id = ministry_terminal_id,
        owner = registered.owner,
        attached = true,
    },
        nil
end

---@param terminal_id string
function M.detach_terminal_context_for_terminal(terminal_id)
    for ministry_terminal_id, binding in pairs(ministry_terminal_context_bindings) do
        if binding.terminal_id == terminal_id then
            ministry_terminal_context_bindings[ministry_terminal_id] = nil
        end
    end
end

function M.clear_bindings()
    ministry_terminal_context_bindings = {}
end

return M

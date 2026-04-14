local registry = require('terminalia.terminal.registry')

local M = {}

---@type table<string, string>
local ministry_terminal_context_bindings = {}

---@param context_stack_for_terminal fun(id: string): { id: string, kind: string, label: string }[]
---@return fun(item: table): table<string, any>|nil
local function terminal_list_data_provider(context_stack_for_terminal)
    return function(item)
        if type(item) ~= 'table' or type(item.terminal_id) ~= 'string' then
            return nil
        end

        local terminal_id = ministry_terminal_context_bindings[item.terminal_id]
        if terminal_id == nil then
            return nil
        end

        local terminal = registry.get(terminal_id)
        if terminal == nil then
            ministry_terminal_context_bindings[item.terminal_id] = nil
            return nil
        end

        return {
            terminalia_context_stack = context_stack_for_terminal(terminal.id),
        }
    end
end

---@param ministry_terminal_id string
---@param terminal_id string
---@param context_stack_for_terminal fun(id: string): { id: string, kind: string, label: string }[]
---@return table|nil, table|nil
function M.attach_terminal_context(ministry_terminal_id, terminal_id, context_stack_for_terminal)
    local ministry = assert(package.loaded.ministry or require('ministry'), 'ministry.nvim is not installed')

    if type(ministry) ~= 'table' or type(ministry.register_list_item_data_provider) ~= 'function' then
        error('ministry.nvim does not expose register_list_item_data_provider')
    end

    local registered, register_err = ministry.register_list_item_data_provider(
        'terminals',
        'terminalia',
        terminal_list_data_provider(context_stack_for_terminal)
    )
    if register_err ~= nil then
        return nil, register_err
    end

    assert(registry.get(terminal_id) ~= nil, string.format('Unknown terminal id: %s', terminal_id))
    ministry_terminal_context_bindings[ministry_terminal_id] = terminal_id

    return {
        list_name = registered.list_name,
        item_id = ministry_terminal_id,
        owner = registered.owner,
        attached = true,
    },
        nil
end

function M.clear_bindings()
    ministry_terminal_context_bindings = {}
end

return M

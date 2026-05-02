local contexts = require('terminalia.context.state')

local M = {}

local providers = {}

---@param command string|string[]
---@return string[]
local function normalize_command(command)
    if type(command) == 'table' then
        return vim.deepcopy(command)
    end

    return { 'sh', '-lc', command }
end

---@param command string|string[]
---@return string
local function display_command(command)
    if type(command) == 'table' then
        return table.concat(command, ' ')
    end

    return command
end

local function register_host_provider()
    providers.host = {
        plan_command = function(context, command, opts)
            local cfg = require('terminalia.config').get()

            return {
                context = context,
                cmd = normalize_command(command),
                cwd = opts and opts.cwd or vim.fn.getcwd(),
                env = opts and opts.env and vim.deepcopy(opts.env) or nil,
                default_name = string.format('%s %s', context.label, display_command(command)),
                terminal_name = opts and opts.terminal_name or display_command(command),
                terminal_namespace = opts and opts.terminal_namespace or cfg.overseer_terminal_namespace,
                metadata = {},
            }
        end,
    }
end

function M.reset()
    providers = {}
    register_host_provider()
end

---@param kind string
---@param provider { plan_command: fun(context: terminalia.TerminalContext, command: string|string[], opts?: table): table, transform_terminal_action?: fun(context: terminalia.TerminalContext, action: terminalia.TerminalAction, terminal: terminalia.TerminalRecord): terminalia.TerminalAction?|false, restore_context?: fun(context_spec: terminalia.TerminalContext, parent_context: terminalia.TerminalContext): terminalia.TerminalContext? }
function M.register(kind, provider)
    assert(type(kind) == 'string' and kind ~= '', 'Context provider kind must be a non-empty string')
    assert(
        type(provider) == 'table'
            and type(provider.plan_command) == 'function'
            and (provider.transform_terminal_action == nil or type(provider.transform_terminal_action) == 'function')
            and (provider.restore_context == nil or type(provider.restore_context) == 'function'),
        'Context provider must define plan_command and may define transform_terminal_action or restore_context'
    )
    providers[kind] = provider
end

---@param kind string
---@return table?
function M.get(kind)
    return providers[kind]
end

---@param context terminalia.TerminalContext
---@param command string|string[]
---@param opts? table
---@return table
function M.plan_command(context, command, opts)
    local provider = assert(
        providers[context.kind],
        string.format('No terminal context provider registered for kind: %s', context.kind)
    )
    return provider.plan_command(context, command, opts)
end

---@param context terminalia.TerminalContext
---@param action terminalia.TerminalAction
---@param terminal terminalia.TerminalRecord
---@return terminalia.TerminalAction?|false
function M.transform_terminal_action(context, action, terminal)
    local provider = providers[context.kind]

    if provider == nil or type(provider.transform_terminal_action) ~= 'function' then
        return action
    end

    local transformed = provider.transform_terminal_action(context, action, terminal)

    if transformed == nil then
        return action
    end

    return transformed
end

---@param context_spec terminalia.TerminalContext
---@param parent_context terminalia.TerminalContext
---@return terminalia.TerminalContext
function M.restore_context(context_spec, parent_context)
    if context_spec.kind == 'host' or context_spec.id == contexts.host().id then
        return contexts.host()
    end

    local existing = contexts.get(context_spec.id)

    if existing ~= nil then
        return existing
    end

    local provider = providers[context_spec.kind]

    if provider ~= nil and type(provider.restore_context) == 'function' then
        local restored = provider.restore_context(context_spec, parent_context)

        if restored ~= nil then
            return restored
        end
    end

    return contexts.create_child(parent_context.id, {
        id = context_spec.id,
        kind = context_spec.kind,
        label = context_spec.label,
        metadata = vim.deepcopy(context_spec.metadata or {}),
    })
end

---@param stack terminalia.TerminalContext[]
---@return terminalia.TerminalContext
function M.restore_context_stack(stack)
    local current = contexts.host()

    for _, context_spec in ipairs(stack) do
        current = M.restore_context(context_spec, current)
    end

    return current
end

M.reset()

return M

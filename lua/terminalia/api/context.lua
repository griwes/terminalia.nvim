local config = require('terminalia.config')
local contexts = require('terminalia.context.state')
local context_providers = require('terminalia.context.providers')
local ministry_integration = require('terminalia.integrations.ministry')
local overseer = require('terminalia.overseer')
local registry = require('terminalia.terminal.registry')

local M = {}

local function notify_session()
    local ok, session_plugin = pcall(require, 'continuity')

    if ok and type(session_plugin) == 'table' and type(session_plugin.api) == 'table' then
        if type(session_plugin.api.notify_contributor_changed) == 'function' then
            pcall(session_plugin.api.notify_contributor_changed, 'terminalia')
        end
    end
end

---@param context terminalia.TerminalContext
---@return { id: string, kind: string, label: string }[]
local function build_context_stack(context)
    local stack = {}
    local seen = {}
    local current = context

    while type(current) == 'table' and type(current.id) == 'string' and not seen[current.id] do
        seen[current.id] = true
        table.insert(stack, 1, {
            id = current.id,
            kind = current.kind,
            label = current.label,
        })

        if type(current.parent_id) ~= 'string' or current.parent_id == '' then
            break
        end

        current =
            assert(contexts.get(current.parent_id), string.format('Unknown terminal context id: %s', current.parent_id))
    end

    return stack
end

---@param opts terminalia.ContextCreateOptions
---@return terminalia.TerminalContext
function M.create_context(opts)
    local context = contexts.create(opts)
    notify_session()
    return context
end

---@param parent_id string
---@param opts? terminalia.ContextCreateOptions
---@return terminalia.TerminalContext
function M.create_child_context(parent_id, opts)
    local context = contexts.create_child(parent_id, opts)
    notify_session()
    return context
end

---@return terminalia.TerminalContext
function M.host_context()
    return contexts.host()
end

---@return terminalia.TerminalContext[]
function M.list_contexts()
    return contexts.list()
end

---@param id string
---@return terminalia.TerminalContext?
function M.get_context(id)
    return contexts.get(id)
end

---@param context_id? string
---@return { id: string, kind: string, label: string }[]
function M.context_stack(context_id)
    local context = context_id == nil and contexts.current()
        or assert(contexts.get(context_id), string.format('Unknown terminal context id: %s', context_id))

    return build_context_stack(context)
end

---@param id string
---@return { id: string, kind: string, label: string }[]
function M.context_stack_for_terminal(id)
    local terminal = assert(registry.get(id), string.format('Unknown terminal id: %s', id))
    return M.context_stack(terminal.context_id)
end

---@param ministry_terminal_id string
---@param terminal_id string
---@return table|nil, table|nil
function M.attach_ministry_terminal_context(ministry_terminal_id, terminal_id)
    return ministry_integration.attach_terminal_context(ministry_terminal_id, terminal_id, M.context_stack_for_terminal)
end

---@param stack terminalia.TerminalContext[]
---@return terminalia.TerminalContext
function M.restore_context_stack(stack)
    return context_providers.restore_context_stack(stack)
end

---@return terminalia.TerminalContext
function M.current_context()
    return contexts.current()
end

---@param id string
---@return terminalia.TerminalContext
function M.set_current_context(id)
    local context = contexts.set_current(id)
    notify_session()
    return context
end

---@return terminalia.TerminalContext
function M.clear_current_context()
    local context = contexts.clear_current()
    notify_session()
    return context
end

---@param kind string
---@param provider table
function M.register_context_provider(kind, provider)
    context_providers.register(kind, provider)
end

---@param context_id? string
---@return terminalia.TerminalContext
function M.overseer_context(context_id)
    return overseer.resolve_context(context_id)
end

---@param id string
---@return terminalia.TerminalContext
function M.set_overseer_context(id)
    assert(contexts.get(id) ~= nil, string.format('Unknown terminal context id: %s', id))
    config.set_overseer_context(id)
    return overseer.resolve_context(id)
end

---@return terminalia.TerminalContext
function M.clear_overseer_context()
    config.clear_overseer_context()
    return overseer.resolve_context()
end

---@param command string|string[]
---@param opts? table
---@return table<string, any>
function M.build_overseer_task(command, opts)
    return overseer.build_task_definition(command, opts)
end

---@param command string|string[]
---@param opts? table
---@return overseer.Task
function M.new_overseer_task(command, opts)
    return overseer.new_task(command, opts)
end

---@param command string|string[]
---@param opts? table
---@return overseer.Task
function M.run_overseer_task(command, opts)
    return overseer.run_task(command, opts)
end

---@param template table
function M.register_overseer_template(template)
    overseer.register_template(template)
end

return M

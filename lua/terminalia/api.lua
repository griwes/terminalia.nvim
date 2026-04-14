local config = require('terminalia.config')
local contexts = require('terminalia.context.state')
local context_providers = require('terminalia.context.providers')
local history = require('terminalia.history')
local ministry_integration = require('terminalia.integrations.ministry')
local overseer = require('terminalia.overseer')
local registry = require('terminalia.terminal.registry')
local runtime = require('terminalia.runtime.native')
local uri = require('terminalia.uri')
local history_view = require('terminalia.view.history')
local split_view = require('terminalia.view.split')
local float_view = require('terminalia.view.float')

local M = {}
local openers = {
    split = split_view.open,
    float = float_view.open,
}

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

---@param terminal terminalia.TerminalRecord
---@param opts? { view?: terminalia.ViewKind }
---@return terminalia.ViewKind
local function resolve_view(terminal, opts)
    local view = opts and opts.view or terminal.preferred_view or config.get().default_view

    if openers[view] == nil then
        error(string.format('Unsupported terminal view: %s', view))
    end

    return view
end

---@param terminal terminalia.TerminalRecord
---@param view terminalia.ViewKind
local function reveal(terminal, view)
    return openers[view](terminal, config.get())
end

---Create a terminal record without opening it.
---@param opts? Partial<terminalia.CreateOptions>
---@return terminalia.TerminalRecord
function M.create(opts)
    local terminal = registry.create(opts)
    notify_session()
    return terminal
end

---Create a terminal context record.
---@param opts terminalia.ContextCreateOptions
---@return terminalia.TerminalContext
function M.create_context(opts)
    local context = contexts.create(opts)
    notify_session()
    return context
end

---Create a child terminal context record.
---@param parent_id string
---@param opts? terminalia.ContextCreateOptions
---@return terminalia.TerminalContext
function M.create_child_context(parent_id, opts)
    local context = contexts.create_child(parent_id, opts)
    notify_session()
    return context
end

---Return the host/root terminal context.
---@return terminalia.TerminalContext
function M.host_context()
    return contexts.host()
end

---Return all known terminal contexts.
---@return terminalia.TerminalContext[]
function M.list_contexts()
    return contexts.list()
end

---Return a terminal context by id.
---@param id string
---@return terminalia.TerminalContext?
function M.get_context(id)
    return contexts.get(id)
end

---Return a lightweight stack summary for a context id or the current context.
---@param context_id? string
---@return { id: string, kind: string, label: string }[]
function M.context_stack(context_id)
    local context = context_id == nil and contexts.current()
        or assert(contexts.get(context_id), string.format('Unknown terminal context id: %s', context_id))

    return build_context_stack(context)
end

---Return a lightweight stack summary for a terminal's bound creation context.
---@param id string
---@return { id: string, kind: string, label: string }[]
function M.context_stack_for_terminal(id)
    local terminal = assert(registry.get(id), string.format('Unknown terminal id: %s', id))
    return M.context_stack(terminal.context_id)
end

---Attach a terminal-owned Terminalia context stack to a Ministry terminal record.
---@param ministry_terminal_id string
---@param terminal_id string
---@return table|nil, table|nil
function M.attach_ministry_terminal_context(ministry_terminal_id, terminal_id)
    return ministry_integration.attach_terminal_context(ministry_terminal_id, terminal_id, M.context_stack_for_terminal)
end

---Restore a saved context stack through registered providers.
---@param stack terminalia.TerminalContext[]
---@return terminalia.TerminalContext
function M.restore_context_stack(stack)
    return context_providers.restore_context_stack(stack)
end

---Return the current terminal context.
---@return terminalia.TerminalContext
function M.current_context()
    return contexts.current()
end

---Set the current terminal context.
---@param id string
---@return terminalia.TerminalContext
function M.set_current_context(id)
    local context = contexts.set_current(id)
    notify_session()
    return context
end

---Reset the current terminal context back to the host context.
---@return terminalia.TerminalContext
function M.clear_current_context()
    local context = contexts.clear_current()
    notify_session()
    return context
end

---Register a terminal context provider.
---@param kind string
---@param provider table
function M.register_context_provider(kind, provider)
    context_providers.register(kind, provider)
end

---Return the effective Overseer context.
---@param context_id? string
---@return terminalia.TerminalContext
function M.overseer_context(context_id)
    return overseer.resolve_context(context_id)
end

---Set the explicit Overseer context override.
---@param id string
---@return terminalia.TerminalContext
function M.set_overseer_context(id)
    assert(contexts.get(id) ~= nil, string.format('Unknown terminal context id: %s', id))
    config.set_overseer_context(id)
    return overseer.resolve_context(id)
end

---Clear the explicit Overseer context override.
---@return terminalia.TerminalContext
function M.clear_overseer_context()
    config.clear_overseer_context()
    return overseer.resolve_context()
end

---Build an Overseer task definition from the current or explicit context.
---@param command string|string[]
---@param opts? table
---@return table<string, any>
function M.build_overseer_task(command, opts)
    return overseer.build_task_definition(command, opts)
end

---Create an Overseer task from the current or explicit context.
---@param command string|string[]
---@param opts? table
---@return overseer.Task
function M.new_overseer_task(command, opts)
    return overseer.new_task(command, opts)
end

---Create and start an Overseer task from the current or explicit context.
---@param command string|string[]
---@param opts? table
---@return overseer.Task
function M.run_overseer_task(command, opts)
    return overseer.run_task(command, opts)
end

---Register an Overseer template through the current or explicit context.
---@param template table
function M.register_overseer_template(template)
    overseer.register_template(template)
end

---@param uri_value string
---@return { kind: string, terminal_id: string, name: string, context_id?: string, context_stack_ids: string[] }?, string?
function M.decode_uri(uri_value)
    return uri.decode(uri_value)
end

---Open a Terminalia URI through the normal terminal/history surfaces.
---@param uri_value string
---@param opts? { view?: terminalia.ViewKind }
---@return integer|terminalia.TerminalRecord
function M.open_uri(uri_value, opts)
    local decoded, err = uri.decode(uri_value)

    if decoded == nil then
        error(assert(err))
    end

    if decoded.context_id ~= nil then
        local restored_context = contexts.get(decoded.context_id)

        if restored_context == nil and decoded.context_stack ~= nil and #decoded.context_stack > 0 then
            restored_context = context_providers.restore_context_stack(decoded.context_stack)
        end

        if restored_context ~= nil then
            contexts.set_current(restored_context.id)
        end
    end

    if decoded.kind == 'history' then
        return M.open_history(decoded.terminal_id)
    end

    return M.open(decoded.terminal_id, opts)
end

---Create and immediately reveal a terminal.
---@param opts? Partial<terminalia.CreateOptions>
---@return terminalia.TerminalRecord
function M.create_and_open(opts)
    local terminal = M.create(opts)
    return M.open(terminal.id, {
        view = opts and opts.view,
    })
end

---Start a terminal without revealing a window.
---@param id string
---@return terminalia.TerminalRecord
function M.start(id)
    local terminal = assert(registry.get(id), string.format('Unknown terminal id: %s', id))
    return runtime.ensure_started(terminal)
end

---Look up a terminal by id.
---@param id string
---@return terminalia.TerminalRecord?
function M.get(id)
    return registry.get(id)
end

---Reveal an existing terminal and start the runtime if necessary.
---@param id string
---@param opts? { view?: terminalia.ViewKind }
---@return terminalia.TerminalRecord
function M.open(id, opts)
    local terminal = assert(registry.get(id), string.format('Unknown terminal id: %s', id))
    local view = resolve_view(terminal, opts)

    runtime.ensure_started(terminal)
    reveal(terminal, view)

    return registry.update(id, {
        last_opened_at = os.time(),
        preferred_view = view,
    })
end

---Return all known terminals.
---@param filters? terminalia.ListFilters
---@return terminalia.TerminalRecord[]
function M.list(filters)
    return registry.list(filters)
end

---@return table
function M.session_capture()
    local terminals = {}

    for _, terminal in ipairs(M.list()) do
        table.insert(terminals, {
            id = terminal.id,
            name = terminal.name,
            namespace = terminal.namespace,
            cwd = terminal.cwd,
            context_id = terminal.context_id,
            preferred_view = terminal.preferred_view,
            disposable = terminal.disposable,
            status = terminal.status,
            uri = uri.encode_terminal_uri(terminal),
        })
    end

    return {
        current_context_id = M.current_context().id,
        terminals = terminals,
    }
end

---Build restore-plan steps for captured Terminalia session state.
---@param captured table
---@return continuity.RestorePlanStep[]
function M.session_plan_restore(captured)
    local terminals = type(captured) == 'table' and type(captured.terminals) == 'table' and captured.terminals or {}

    if #terminals > 0 then
        local items = {}

        for _, terminal in ipairs(terminals) do
            if type(terminal.uri) == 'string' and terminal.uri ~= '' then
                table.insert(items, {
                    id = terminal.id,
                    uri = terminal.uri,
                    name = terminal.name,
                    namespace = terminal.namespace,
                    preferred_view = terminal.preferred_view,
                    disposable = terminal.disposable,
                })
            end
        end

        if #items > 0 then
            return {
                {
                    kind = 'terminalia.reopen_terminals',
                    title = 'Reopen terminal buffers',
                    detail = string.format('Reopen %d Terminalia terminal(s) from canonical URIs', #items),
                    payload = {
                        current_context_id = captured.current_context_id,
                        terminals = items,
                    },
                },
            }
        end
    end

    if
        type(captured) == 'table'
        and captured.current_context_id ~= nil
        and captured.current_context_id ~= 'context:host'
    then
        return {
            {
                kind = 'continuity.manual_restore',
                title = 'Review Terminalia context',
                detail = 'A non-host terminal context was captured without reopenable terminal URIs',
                payload = {
                    current_context_id = captured.current_context_id,
                },
                manual = true,
            },
        }
    end

    return {}
end

---@param step continuity.RestorePlanStep
function M.session_restore(step)
    if step.kind ~= 'terminalia.reopen_terminals' then
        error(string.format('Unsupported Terminalia restore step: %s', step.kind))
    end

    local reopened = {}

    for _, terminal in ipairs(step.payload.terminals or {}) do
        table.insert(
            reopened,
            M.open_uri(terminal.uri, {
                view = terminal.preferred_view,
            })
        )
    end

    return reopened
end

---Update the tracked cwd metadata for a terminal.
---@param id string
---@param cwd string
---@return terminalia.TerminalRecord
function M.set_cwd(id, cwd)
    local terminal = registry.update(id, {
        cwd = cwd,
    })
    notify_session()
    return terminal
end

---Update tracked terminal metadata.
---@param id string
---@param patch table<string, any>
---@return terminalia.TerminalRecord
function M.update(id, patch)
    local terminal = registry.update(id, patch)
    notify_session()
    return terminal
end

---Send stdin to a started terminal job.
---@param id string
---@param data string
---@return terminalia.TerminalRecord
function M.send(id, data)
    local terminal = assert(registry.get(id), string.format('Unknown terminal id: %s', id))
    return runtime.send(terminal, data)
end

---Return the captured history lines for a terminal id.
---@param id string
---@return string[]
function M.history_lines(id)
    local terminal = registry.get(id) or runtime.exited_terminal(id)

    assert(terminal ~= nil, string.format('Unknown terminal id: %s', id))

    return history.read_lines(id)
end

---Return the captured output snapshot for a terminal id.
---@param id string
---@return terminalia.TerminalOutput
function M.output(id)
    local terminal = registry.get(id) or runtime.exited_terminal(id)

    assert(terminal ~= nil, string.format('Unknown terminal id: %s', id))

    local output, has_live_output = runtime.output(id)

    if not has_live_output then
        output = history.read_text(id)
    end

    return {
        output = output,
        status = terminal.status,
        exit_code = terminal.exit_code,
    }
end

---Wait for a terminal job to exit.
---@param id string
---@param timeout_ms? integer
---@return terminalia.TerminalRecord?
function M.wait(id, timeout_ms)
    local terminal = registry.get(id)

    if terminal == nil then
        terminal = {
            id = id,
        }
    end

    return runtime.wait_for_exit(terminal, timeout_ms)
end

---Request termination of a terminal job.
---@param id string
---@return terminalia.TerminalRecord
function M.kill(id)
    local terminal = assert(registry.get(id), string.format('Unknown terminal id: %s', id))
    return runtime.kill(terminal)
end

---Open a scratch history view for a terminal id.
---@param id string
---@return integer
function M.open_history(id)
    local terminal = registry.get(id) or runtime.exited_terminal(id)

    assert(terminal ~= nil, string.format('Unknown terminal id: %s', id))

    local lines = history.read_lines(id)

    return history_view.open(terminal, lines, config.get())
end

---Format terminals for command-line display.
---@param filters? terminalia.ListFilters
---@return string[]
function M.list_lines(filters)
    local lines = {}

    for _, terminal in ipairs(M.list(filters)) do
        table.insert(
            lines,
            string.format(
                '%s  [%s]  %s  %s  %s',
                terminal.id,
                terminal.namespace,
                terminal.status,
                terminal.cwd or '-',
                terminal.name or terminal.id
            )
        )
    end

    return lines
end

---Remove a terminal from the registry.
---@param id string
---@return terminalia.TerminalRecord?
function M.delete(id)
    if registry.get(id) == nil then
        return nil
    end

    return M.release(id)
end

---Stop a terminal if needed and remove it from the registry.
---@param id string
---@return terminalia.TerminalRecord?
function M.release(id)
    local registered = registry.get(id)
    local exited = registered == nil and runtime.exited_terminal(id) or nil
    local terminal = registered or exited

    if terminal == nil then
        history.clear(id)
        runtime.clear_output(id)
        return nil
    end

    if registered == nil then
        local released = runtime.release_exited_terminal(id)
        notify_session()
        return released
    end

    if terminal.status == 'running' then
        runtime.kill(terminal)
        terminal = runtime.wait_for_exit(terminal, 1000) or terminal
    end

    history.clear(id)
    runtime.clear_output(id)
    local released = registry.remove(id, { clear_history = false }) or terminal
    notify_session()
    return released
end

---Restore any persisted terminal metadata into the registry.
---When `merge` is true, existing in-memory terminals are preserved and restored
---records that reuse an existing id are reassigned a fresh id.
---@param opts? { force?: boolean, merge?: boolean }
function M.restore(opts)
    if opts ~= nil and opts.force == true and opts.merge ~= true then
        runtime.clear()
    end

    registry.restore(opts)
end

---Reset all in-memory state.
---@param opts? { wipe_storage?: boolean, reset_setup_state?: boolean }
function M.clear(opts)
    runtime.clear()
    registry.clear(opts)
    ministry_integration.clear_bindings()
    notify_session()

    if opts ~= nil and opts.wipe_storage == false and opts.reset_setup_state ~= false then
        require('terminalia')._reset_setup_state()
    end
end

return M

local config = require('terminal_manager.config')
local contexts = require('terminal_manager.contexts')
local context_providers = require('terminal_manager.context_providers')
local history = require('terminal_manager.history')
local overseer = require('terminal_manager.overseer')
local registry = require('terminal_manager.registry')
local runtime = require('terminal_manager.runtime.native')
local uri = require('terminal_manager.uri')
local history_view = require('terminal_manager.view.history')
local split_view = require('terminal_manager.view.split')
local float_view = require('terminal_manager.view.float')

local M = {}
local openers = {
    split = split_view.open,
    float = float_view.open,
}

local function notify_session()
    local ok, session_plugin = pcall(require, 'session')

    if ok and type(session_plugin) == 'table' and type(session_plugin.api) == 'table' then
        if type(session_plugin.api.notify_contributor_changed) == 'function' then
            pcall(session_plugin.api.notify_contributor_changed, 'terminal_manager')
        end
    end
end

---@param terminal terminal_manager.TerminalRecord
---@param opts? { view?: terminal_manager.ViewKind }
---@return terminal_manager.ViewKind
local function resolve_view(terminal, opts)
    local view = opts and opts.view or terminal.preferred_view or config.get().default_view

    if openers[view] == nil then
        error(string.format('Unsupported terminal view: %s', view))
    end

    return view
end

---@param terminal terminal_manager.TerminalRecord
---@param view terminal_manager.ViewKind
local function reveal(terminal, view)
    return openers[view](terminal, config.get())
end

---Create a terminal record without opening it.
---@param opts? Partial<terminal_manager.CreateOptions>
---@return terminal_manager.TerminalRecord
function M.create(opts)
    local terminal = registry.create(opts)
    notify_session()
    return terminal
end

---Create a terminal context record.
---@param opts terminal_manager.ContextCreateOptions
---@return terminal_manager.TerminalContext
function M.create_context(opts)
    local context = contexts.create(opts)
    notify_session()
    return context
end

---Create a child terminal context record.
---@param parent_id string
---@param opts? terminal_manager.ContextCreateOptions
---@return terminal_manager.TerminalContext
function M.create_child_context(parent_id, opts)
    local context = contexts.create_child(parent_id, opts)
    notify_session()
    return context
end

---Return the host/root terminal context.
---@return terminal_manager.TerminalContext
function M.host_context()
    return contexts.host()
end

---Return all known terminal contexts.
---@return terminal_manager.TerminalContext[]
function M.list_contexts()
    return contexts.list()
end

---Return a terminal context by id.
---@param id string
---@return terminal_manager.TerminalContext?
function M.get_context(id)
    return contexts.get(id)
end

---Restore a saved context stack through registered providers.
---@param stack terminal_manager.TerminalContext[]
---@return terminal_manager.TerminalContext
function M.restore_context_stack(stack)
    return context_providers.restore_context_stack(stack)
end

---Return the current terminal context.
---@return terminal_manager.TerminalContext
function M.current_context()
    return contexts.current()
end

---Set the current terminal context.
---@param id string
---@return terminal_manager.TerminalContext
function M.set_current_context(id)
    local context = contexts.set_current(id)
    notify_session()
    return context
end

---Reset the current terminal context back to the host context.
---@return terminal_manager.TerminalContext
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
---@return terminal_manager.TerminalContext
function M.overseer_context(context_id)
    return overseer.resolve_context(context_id)
end

---Set the explicit Overseer context override.
---@param id string
---@return terminal_manager.TerminalContext
function M.set_overseer_context(id)
    assert(contexts.get(id) ~= nil, string.format('Unknown terminal context id: %s', id))
    config.set_overseer_context(id)
    return overseer.resolve_context(id)
end

---Clear the explicit Overseer context override.
---@return terminal_manager.TerminalContext
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

---Open a terminal-manager URI through the normal terminal/history surfaces.
---@param uri_value string
---@param opts? { view?: terminal_manager.ViewKind }
---@return integer|terminal_manager.TerminalRecord
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
---@param opts? Partial<terminal_manager.CreateOptions>
---@return terminal_manager.TerminalRecord
function M.create_and_open(opts)
    local terminal = M.create(opts)
    return M.open(terminal.id, {
        view = opts and opts.view,
    })
end

---Start a terminal without revealing a window.
---@param id string
---@return terminal_manager.TerminalRecord
function M.start(id)
    local terminal = assert(registry.get(id), string.format('Unknown terminal id: %s', id))
    return runtime.ensure_started(terminal)
end

---Look up a terminal by id.
---@param id string
---@return terminal_manager.TerminalRecord?
function M.get(id)
    return registry.get(id)
end

---Reveal an existing terminal and start the runtime if necessary.
---@param id string
---@param opts? { view?: terminal_manager.ViewKind }
---@return terminal_manager.TerminalRecord
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
---@param filters? terminal_manager.ListFilters
---@return terminal_manager.TerminalRecord[]
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

---Build restore-plan steps for captured terminal-manager session state.
---@param captured table
---@return session.RestorePlanStep[]
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
                    kind = 'terminal_manager.reopen_terminals',
                    title = 'Reopen terminal buffers',
                    detail = string.format('Reopen %d terminal-manager terminal(s) from canonical URIs', #items),
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
                kind = 'session.manual_restore',
                title = 'Review terminal-manager context',
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

---Update the tracked cwd metadata for a terminal.
---@param id string
---@param cwd string
---@return terminal_manager.TerminalRecord
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
---@return terminal_manager.TerminalRecord
function M.update(id, patch)
    local terminal = registry.update(id, patch)
    notify_session()
    return terminal
end

---Send stdin to a started terminal job.
---@param id string
---@param data string
---@return terminal_manager.TerminalRecord
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
---@return terminal_manager.TerminalOutput
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
---@return terminal_manager.TerminalRecord?
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
---@return terminal_manager.TerminalRecord
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
---@param filters? terminal_manager.ListFilters
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
---@return terminal_manager.TerminalRecord?
function M.delete(id)
    if registry.get(id) == nil then
        return nil
    end

    return M.release(id)
end

---Stop a terminal if needed and remove it from the registry.
---@param id string
---@return terminal_manager.TerminalRecord?
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
    notify_session()

    if opts ~= nil and opts.wipe_storage == false and opts.reset_setup_state ~= false then
        require('terminal_manager')._reset_setup_state()
    end
end

return M

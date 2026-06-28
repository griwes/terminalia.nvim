local config = require('terminalia.config')
local context_api = require('terminalia.api.context')
local context_state = require('terminalia.context.state')
local uri_api = require('terminalia.api.uri')
local history = require('terminalia.history')
local ministry_integration = require('terminalia.integrations.ministry')
local relay_args = require('terminalia.relay.args')
local relay_open = require('terminalia.relay.open')
local terminal_action_protocol = require('terminalia.terminal.action_protocol')
local registry = require('terminalia.terminal.registry')
local runtime = require('terminalia.runtime.native')
local shell_integration = require('terminalia.terminal.shell_integration')
local uri = require('terminalia.uri')
local history_view = require('terminalia.view.history')

local M = {}

local function notify_session()
    local ok, session_plugin = pcall(require, 'continuity')

    if ok and type(session_plugin) == 'table' and type(session_plugin.api) == 'table' then
        if type(session_plugin.api.notify_contributor_changed) == 'function' then
            pcall(session_plugin.api.notify_contributor_changed, 'terminalia')
        end
    end
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
    return context_api.create_context(opts)
end

---Create a child terminal context record.
---@param parent_id string
---@param opts? terminalia.ContextCreateOptions
---@return terminalia.TerminalContext
function M.create_child_context(parent_id, opts)
    return context_api.create_child_context(parent_id, opts)
end

---Return the host/root terminal context.
---@return terminalia.TerminalContext
function M.host_context()
    return context_api.host_context()
end

---Return all known terminal contexts.
---@return terminalia.TerminalContext[]
function M.list_contexts()
    return context_api.list_contexts()
end

---Return a terminal context by id.
---@param id string
---@return terminalia.TerminalContext?
function M.get_context(id)
    return context_api.get_context(id)
end

---Return a lightweight stack summary for a context id or the current context.
---@param context_id? string
---@return { id: string, kind: string, label: string }[]
function M.context_stack(context_id)
    return context_api.context_stack(context_id)
end

---Return a lightweight stack summary for a terminal's bound creation context.
---@param id string
---@return { id: string, kind: string, label: string }[]
function M.context_stack_for_terminal(id)
    return context_api.context_stack_for_terminal(id)
end

---Attach a terminal-owned Terminalia context stack to a Ministry terminal record.
---@param ministry_terminal_id string
---@param terminal_id string
---@return table|nil, table|nil
function M.attach_ministry_terminal_context(ministry_terminal_id, terminal_id)
    return context_api.attach_ministry_terminal_context(ministry_terminal_id, terminal_id)
end

---Register automatic context propagation for Ministry-owned terminals.
---@return table|nil, table|nil
function M.setup_ministry_integration()
    return context_api.setup_ministry_integration()
end

---Restore a saved context stack through registered providers.
---@param stack terminalia.TerminalContext[]
---@return terminalia.TerminalContext
function M.restore_context_stack(stack)
    return context_api.restore_context_stack(stack)
end

---Return the current terminal context.
---@return terminalia.TerminalContext
function M.current_context()
    return context_api.current_context()
end

---Set the current terminal context.
---@param id string
---@return terminalia.TerminalContext
function M.set_current_context(id)
    return context_api.set_current_context(id)
end

---Reset the current terminal context back to the host context.
---@return terminalia.TerminalContext
function M.clear_current_context()
    return context_api.clear_current_context()
end

---Register a terminal context provider.
---@param kind string
---@param provider table
function M.register_context_provider(kind, provider)
    return context_api.register_context_provider(kind, provider)
end

---Return the effective Overseer context.
---@param context_id? string
---@return terminalia.TerminalContext
function M.overseer_context(context_id)
    return context_api.overseer_context(context_id)
end

---Set the explicit Overseer context override.
---@param id string
---@return terminalia.TerminalContext
function M.set_overseer_context(id)
    return context_api.set_overseer_context(id)
end

---Clear the explicit Overseer context override.
---@return terminalia.TerminalContext
function M.clear_overseer_context()
    return context_api.clear_overseer_context()
end

---Build an Overseer task definition from the current or explicit context.
---@param command string|string[]
---@param opts? table
---@return table<string, any>
function M.build_overseer_task(command, opts)
    return context_api.build_overseer_task(command, opts)
end

---Create an Overseer task from the current or explicit context.
---@param command string|string[]
---@param opts? table
---@return overseer.Task
function M.new_overseer_task(command, opts)
    return context_api.new_overseer_task(command, opts)
end

---Create and start an Overseer task from the current or explicit context.
---@param command string|string[]
---@param opts? table
---@return overseer.Task
function M.run_overseer_task(command, opts)
    return context_api.run_overseer_task(command, opts)
end

---Register an Overseer template through the current or explicit context.
---@param template table
function M.register_overseer_template(template)
    return context_api.register_overseer_template(template)
end

---@param uri_value string
---@return { kind: string, terminal_id: string, name: string, context_id?: string, context_stack_ids: string[] }?, string?
function M.decode_uri(uri_value)
    return uri_api.decode_uri(M, uri_value)
end

---Open a Terminalia URI through the normal terminal/history surfaces.
---@param uri_value string
---@param opts? { view?: terminalia.ViewKind, start_insert?: boolean }
---@return integer|terminalia.TerminalRecord
function M.open_uri(uri_value, opts)
    return uri_api.open_uri(M, uri_value, opts)
end

---Adopt a `terminalia://...` buffer opened by a session manager or `:edit`.
---@param bufnr integer
---@param opts? table
---@return terminalia.TerminalRecord|integer|nil
function M.adopt_uri_buffer(bufnr, opts)
    return uri_api.adopt_uri_buffer(M, bufnr, opts)
end

---Build an external-editor open plan from argv-style arguments.
---@param argv string[]
---@param opts? { cwd?: string, open_policy?: terminalia.ExternalOpenPolicy }
---@return terminalia.ExternalOpenPlan
function M.plan_external_open(argv, opts)
    return relay_args.plan(argv, opts)
end

---Open files from an external-editor argv-style invocation.
---@param argv string[]
---@param opts? { cwd?: string, open_policy?: terminalia.ExternalOpenPolicy, stdin_data?: string|string[] }
---@return terminalia.ExternalOpenTarget[]
function M.open_external(argv, opts)
    local plan = M.plan_external_open(argv, opts)
    return relay_open.open_plan(plan, opts)
end

---Build a Terminalia-owned terminal OSC open action.
---@param payload table
---@return string
function M.build_terminal_open_action(payload)
    return terminal_action_protocol.open_sequence(payload)
end

---Parse a Terminalia-owned terminal OSC action.
---@param sequence string
---@return terminalia.TerminalAction?
function M.parse_terminal_action_sequence(sequence)
    return terminal_action_protocol.parse_sequence(sequence)
end

---Parse a Terminalia-owned terminal OSC open action payload.
---@param sequence string
---@return table?
function M.parse_terminal_action(sequence)
    return terminal_action_protocol.parse_open_sequence(sequence)
end

---Create state for stream-safe Terminalia action stripping.
---@return terminalia.TerminalActionStripState
function M.new_terminal_action_strip_state()
    return terminal_action_protocol.new_strip_state()
end

---Strip Terminalia-owned action markup from terminal output chunks.
---@param chunks string[]?
---@param state? terminalia.TerminalActionStripState
---@return string[]?
function M.strip_terminal_action_chunks(chunks, state)
    return terminal_action_protocol.strip_action_chunks(chunks, state)
end

---Extract Terminalia-owned actions while stripping their markup from output.
---@param chunks string[]?
---@param state? terminalia.TerminalActionStripState
---@return string[]?
---@return terminalia.TerminalAction[]
function M.extract_terminal_action_chunks(chunks, state)
    return terminal_action_protocol.extract_action_chunks(chunks, state)
end

---Build a shell snippet that turns editor commands into Terminalia OSC open actions.
---@param opts? terminalia.ShellIntegrationOptions
---@return string
function M.build_terminal_open_shell_integration(opts)
    return shell_integration.open_action_prelude(opts)
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
---@param opts? { view?: terminalia.ViewKind, start_insert?: boolean }
---@return terminalia.TerminalRecord
function M.open(id, opts)
    return uri_api.open_terminal(M, id, opts)
end

---Return all known terminals.
---@param filters? terminalia.ListFilters
---@return terminalia.TerminalRecord[]
function M.list(filters)
    return registry.list(filters)
end

---@param bufnr integer?
---@return boolean
local function terminal_buffer_is_session_state(bufnr)
    return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end

local MAX_CAPTURE_BYTES = 512 * 1024
local MAX_CAPTURE_CONTEXTS = 128
local MAX_CAPTURE_TERMINALS = 64

local terminal_restore_item

---@param terminal table
---@param restart? boolean
---@return table?
terminal_restore_item = function(terminal, restart)
    local terminal_uri = terminal.uri

    if type(terminal_uri) ~= 'string' then
        local ok, encoded = pcall(uri.encode_terminal_uri, terminal)

        if not ok then
            vim.notify(
                string.format('Skipped Terminalia session terminal with invalid URI data: %s', encoded),
                vim.log.levels.WARN
            )
            return nil
        end

        terminal_uri = encoded
    end

    return vim.deepcopy({
        id = terminal.id,
        uri = terminal_uri,
        name = terminal.name,
        namespace = terminal.namespace,
        cwd = terminal.cwd,
        env = terminal.env,
        command = terminal.command,
        context_id = terminal.context_id,
        preferred_view = terminal.preferred_view,
        disposable = terminal.disposable,
        status = terminal.status,
        instance_id = terminal.instance_id,
        created_at = terminal.created_at,
        last_opened_at = terminal.last_opened_at,
        exit_code = terminal.exit_code,
        restart = restart == true,
    })
end

---@param contexts_by_id table<string, terminalia.TerminalContext>
---@param selected table<string, boolean>
---@param context_id string
---@return boolean
local function add_context_chain(contexts_by_id, selected, context_id)
    local chain = {}
    local seen = {}
    local current_id = context_id

    while type(current_id) == 'string' and current_id ~= '' and not selected[current_id] do
        if seen[current_id] then
            return false
        end
        seen[current_id] = true

        local context = contexts_by_id[current_id]
        if context == nil then
            return false
        end
        table.insert(chain, context)
        current_id = context.parent_id
    end

    if vim.tbl_count(selected) + #chain > MAX_CAPTURE_CONTEXTS then
        return false
    end

    for _, context in ipairs(chain) do
        selected[context.id] = true
    end
    return true
end

---@param terminal_items table[]
---@param current_context_id string
---@return table[], string, table[]
local function select_capture_contexts(terminal_items, current_context_id)
    local all_contexts = M.list_contexts()
    local contexts_by_id = {}
    for _, context in ipairs(all_contexts) do
        contexts_by_id[context.id] = context
    end

    local selected = {}
    if not add_context_chain(contexts_by_id, selected, current_context_id) then
        current_context_id = 'context:host'
        add_context_chain(contexts_by_id, selected, current_context_id)
    end

    local accepted_terminals = {}
    for _, terminal in ipairs(terminal_items) do
        if add_context_chain(contexts_by_id, selected, terminal.context_id or 'context:host') then
            table.insert(accepted_terminals, terminal)
        end
    end

    local captured_contexts = {}
    for _, context in ipairs(all_contexts) do
        if selected[context.id] then
            table.insert(captured_contexts, {
                id = context.id,
                kind = context.kind,
                label = context.label,
                parent_id = context.parent_id,
                metadata = vim.deepcopy(context.metadata or {}),
                created_at = context.created_at,
            })
        end
    end

    return captured_contexts, current_context_id, accepted_terminals
end

---@param payload table
---@return integer?
local function encoded_payload_size(payload)
    local ok, encoded = pcall(vim.json.encode, payload)
    return ok and #encoded or nil
end

---Capture immutable, bounded terminal and context restore data for Continuity.
---Disposable terminals with live buffers are intentionally marked for restart;
---normal Terminalia persistence continues to exclude disposable terminals.
---@return table
function M.session_capture()
    local terminal_items = {}
    local skipped = 0

    for _, terminal in ipairs(M.list()) do
        if terminal_buffer_is_session_state(terminal.bufnr) and type(terminal.id) == 'string' then
            if #terminal_items >= MAX_CAPTURE_TERMINALS then
                skipped = skipped + 1
            else
                local item = terminal_restore_item(terminal, true)
                if item ~= nil then
                    table.insert(terminal_items, item)
                else
                    skipped = skipped + 1
                end
            end
        end
    end

    local current_context_id = M.current_context().id
    local candidate_count = #terminal_items
    local captured_contexts
    captured_contexts, current_context_id, terminal_items = select_capture_contexts(terminal_items, current_context_id)
    skipped = skipped + candidate_count - #terminal_items

    local payload = {
        version = 2,
        current_context_id = current_context_id,
        contexts = captured_contexts,
        terminals = terminal_items,
    }

    local payload_size = encoded_payload_size(payload)
    while (payload_size == nil or payload_size > MAX_CAPTURE_BYTES) and #terminal_items > 0 do
        table.remove(terminal_items)
        skipped = skipped + 1
        captured_contexts, current_context_id, terminal_items =
            select_capture_contexts(terminal_items, current_context_id)
        payload.current_context_id = current_context_id
        payload.contexts = captured_contexts
        payload.terminals = terminal_items
        payload_size = encoded_payload_size(payload)
    end

    if payload_size == nil or payload_size > MAX_CAPTURE_BYTES then
        skipped = skipped + #terminal_items
        payload = {
            version = 2,
            current_context_id = 'context:host',
            contexts = vim.tbl_filter(function(context)
                return context.id == 'context:host'
            end, M.list_contexts()),
            terminals = {},
        }
    end

    if skipped > 0 then
        vim.notify(
            string.format('Skipped %d Terminalia session terminal(s) to keep capture data bounded', skipped),
            vim.log.levels.WARN
        )
    end

    return vim.deepcopy(payload)
end

---@param captured table
---@return table[]
local function legacy_session_restore_items(captured)
    local terminals = type(captured) == 'table' and type(captured.terminals) == 'table' and captured.terminals or {}
    local items = {}

    for _, terminal in ipairs(terminals) do
        if type(terminal) == 'table' and type(terminal.uri) == 'string' and terminal.uri ~= '' then
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

    return items
end

---Build restore-plan steps for captured Terminalia session state.
---@param captured table
---@return continuity.RestorePlanStep[]
function M.session_plan_restore(captured)
    ---@type table[]
    local terminals = {}

    if type(captured) == 'table' and captured.version == 2 and type(captured.terminals) == 'table' then
        for _, terminal in ipairs(captured.terminals) do
            if
                type(terminal) == 'table'
                and type(terminal.id) == 'string'
                and terminal.id ~= ''
                and type(terminal.uri) == 'string'
                and terminal.uri ~= ''
            then
                local item = terminal_restore_item(terminal, terminal.restart == true)
                if item ~= nil then
                    table.insert(terminals, item)
                end
            end
        end
    end

    if #terminals > 0 then
        return {
            {
                kind = 'terminalia.restore_terminal_buffers',
                title = 'Restore terminal buffer state',
                detail = string.format('Restore %d Terminalia terminal buffer record(s)', #terminals),
                payload = {
                    capture_version = 2,
                    current_context_id = captured.current_context_id,
                    contexts = vim.deepcopy(captured.contexts or {}),
                    terminals = terminals,
                },
            },
        }
    end

    local legacy_terminals = type(captured) == 'table'
            and captured.version ~= 2
            and legacy_session_restore_items(captured)
        or {}

    if #legacy_terminals > 0 then
        return {
            {
                kind = 'terminalia.reopen_terminals',
                title = 'Reopen terminal buffers',
                detail = string.format('Reopen %d Terminalia terminal(s) from canonical URIs', #legacy_terminals),
                payload = {
                    current_context_id = captured.current_context_id,
                    terminals = legacy_terminals,
                },
            },
        }
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

---@param terminal table
---@param collision_safe? boolean
---@return terminalia.TerminalRecord?
local function ensure_restored_terminal_record(terminal, collision_safe)
    if type(terminal) ~= 'table' or type(terminal.id) ~= 'string' or terminal.id == '' then
        return nil
    end

    local existing = M.get(terminal.id)

    if existing ~= nil then
        if not collision_safe then
            return existing
        end

        if
            type(terminal.instance_id) == 'string'
            and terminal.instance_id ~= ''
            and existing.instance_id == terminal.instance_id
        then
            return existing
        end
    end

    return registry.create({
        id = existing == nil and terminal.id or nil,
        name = terminal.name,
        namespace = terminal.namespace,
        cwd = terminal.cwd,
        env = terminal.env,
        command = terminal.command,
        context_id = terminal.context_id,
        disposable = terminal.disposable,
        status = terminal.status == 'running' and 'registered' or terminal.status,
        view = terminal.preferred_view,
        instance_id = terminal.instance_id,
        created_at = terminal.created_at,
        last_opened_at = terminal.last_opened_at,
        exit_code = terminal.exit_code,
    })
end

---@param name string?
---@return integer?
local function find_buffer_by_exact_name(name)
    if type(name) ~= 'string' or name == '' then
        return nil
    end

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == name then
            return bufnr
        end
    end
end

---@param bufnr integer
---@return boolean
local function buffer_is_visible(bufnr)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
            return true
        end
    end

    return false
end

---@param record terminalia.TerminalRecord
---@param terminal table
---@return terminalia.TerminalRecord
local function adopt_restored_terminal_buffer(record, terminal)
    local terminal_uri = terminal.uri or uri.encode_terminal_uri(record)
    local bufnr = find_buffer_by_exact_name(terminal_uri)

    if bufnr == nil then
        return record
    end

    if record.id ~= terminal.id then
        pcall(vim.api.nvim_buf_set_name, bufnr, uri.encode_terminal_uri(record))
    end

    vim.b[bufnr].terminalia_id = record.id
    vim.b[bufnr].terminal_manager_id = record.id
    record = registry.update(record.id, {
        bufnr = bufnr,
    })
    require('terminalia.winbar').install(bufnr)

    if
        terminal.restart ~= false
        and buffer_is_visible(bufnr)
        and not (record.status == 'running' and record.job_id ~= nil)
    then
        local ok, started = pcall(M.start, record.id)

        if ok and started ~= nil then
            record = started
        end
    end

    return record
end

---@param step continuity.RestorePlanStep
function M.session_restore(step)
    if type(step) ~= 'table' then
        error('Invalid Terminalia restore step: expected table')
    end

    local is_reopen_step = step.kind == 'terminalia.reopen_terminals'
        or step.kind == 'terminal_manager.reopen_terminals'

    if step.kind ~= 'terminalia.restore_terminal_buffers' and not is_reopen_step then
        error(string.format('Unsupported Terminalia restore step: %s', tostring(step.kind)))
    end

    local payload = type(step.payload) == 'table' and step.payload or {}
    local restored = {}

    if type(payload.terminals) ~= 'table' then
        return restored
    end

    if is_reopen_step then
        for _, terminal in ipairs(payload.terminals) do
            if type(terminal) == 'table' and type(terminal.uri) == 'string' then
                table.insert(
                    restored,
                    M.open_uri(terminal.uri, {
                        view = terminal.preferred_view,
                    })
                )
            end
        end

        return restored
    end

    local context_mapping = context_state.merge_payload({
        contexts = type(payload.contexts) == 'table' and payload.contexts or {},
    })
    local current_context_id = type(payload.current_context_id) == 'string'
            and (context_mapping[payload.current_context_id] or payload.current_context_id)
        or nil

    for _, terminal in ipairs(payload.terminals) do
        terminal = type(terminal) == 'table' and vim.deepcopy(terminal) or terminal
        if type(terminal) == 'table' and terminal.context_id ~= nil then
            terminal.context_id = context_mapping[terminal.context_id] or terminal.context_id
        end

        local record = ensure_restored_terminal_record(terminal, payload.capture_version == 2)

        if record ~= nil then
            record = adopt_restored_terminal_buffer(record, terminal)
            table.insert(restored, record)
        end
    end

    if current_context_id ~= nil and context_state.get(current_context_id) ~= nil then
        context_state.set_current(current_context_id)
    end

    return restored
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

---@param id string
---@return terminalia.TerminalRecord?
local function terminal_with_readable_history(id)
    runtime.finalize_disposable(id)
    return registry.get(id) or runtime.exited_terminal(id)
end

---Return the transcript history lines for a terminal id.
---@param id string
---@return string[]
function M.history_lines(id)
    local terminal = terminal_with_readable_history(id)

    assert(terminal ~= nil, string.format('Unknown terminal id: %s', id))

    local live_output, has_live_output = runtime.output(id)

    if not has_live_output then
        return history.read_lines(id)
    end

    return history.read_lines_with_live_output(id, live_output)
end

---Return the captured output snapshot for a terminal id.
---@param id string
---@return terminalia.TerminalOutput
function M.output(id)
    local terminal = terminal_with_readable_history(id)

    assert(terminal ~= nil, string.format('Unknown terminal id: %s', id))

    local output, has_live_output = runtime.output(id)

    if not has_live_output then
        output = history.read_text(id)
    else
        output = history.read_text_with_live_output(id, output)
    end

    return {
        output = output,
        status = terminal.status,
        exit_code = terminal.exit_code,
    }
end

---Return the captured output snapshot as lines for a terminal id.
---@param id string
---@return string[]
function M.output_lines(id)
    local terminal = terminal_with_readable_history(id)

    assert(terminal ~= nil, string.format('Unknown terminal id: %s', id))

    local live_output, has_live_output = runtime.output(id)

    if not has_live_output then
        return history.read_lines(id)
    end

    return history.read_lines_with_live_output(id, live_output)
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
    local terminal = terminal_with_readable_history(id)

    assert(terminal ~= nil, string.format('Unknown terminal id: %s', id))

    local live_output, has_live_output = runtime.output(id)
    local lines = has_live_output and history.read_lines_with_live_output(id, live_output) or history.read_lines(id)

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
        ministry_integration.detach_terminal_context_for_terminal(id)
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
        ministry_integration.detach_terminal_context_for_terminal(id)
        return nil
    end

    if registered == nil then
        local released = runtime.release_exited_terminal(id)
        ministry_integration.detach_terminal_context_for_terminal(id)
        notify_session()
        return released
    end

    if terminal.status == 'running' then
        runtime.kill(terminal)
        terminal = runtime.wait_for_exit(terminal, 1000) or terminal
    end

    history.clear(id)
    runtime.clear_output(id)
    ministry_integration.detach_terminal_context_for_terminal(id)
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

local config = require('terminalia.config')
local context_providers = require('terminalia.context.providers')
local contexts = require('terminalia.context.state')
local history = require('terminalia.history')
local buffer_helpers = require('terminalia.runtime.buffer')
local action_protocol = require('terminalia.terminal.action_protocol')
local parent_redirect = require('terminalia.relay.parent')
local registry = require('terminalia.terminal.registry')
local shell_integration = require('terminalia.terminal.shell_integration')
local output_helpers = require('terminalia.runtime.output')
local uri = require('terminalia.uri')
local git_tool_relay = require('terminalia.relay.git_tool')

local M = {}
local autocmds_registered = false
---@type table<string, string>
local captured_output = {}
---@type table<string, string>
local pending_output = {}
---@type table<string, terminalia.TerminalRecord>
local exited_disposables = {}
---@type table<string, boolean>
local pending_disposable_cleanup = {}
---@type table<string, integer>
local disposable_bufnrs = {}
---@type table<string, table>
local buffer_state = {}
local session_generation = 0
local cwd_fallback_prefix = '__TERMINALIA_CWD__='
local output_helper
local buffer_helper
local visible_windows_for_buffer
---@type table<string, table<string, terminalia.TerminalActionStripState>>
local action_strip_state = {}
---@type table<string, string[]>
local launch_cleanup_paths = {}
---@type table<string, string[]>
local launch_action_wait_dirs = {}

local disposable_cleanup_group = vim.api.nvim_create_augroup('terminalia-disposable-cleanup', {
    clear = true,
})

---@param path string
---@return boolean
local function regular_directory(path)
    local stat = vim.uv.fs_lstat(path)
    return type(stat) == 'table' and stat.type == 'directory'
end

---@param wait_path string
---@param action_dir string
---@return string?
local function wait_token_path(wait_path, action_dir)
    local normalized_path = vim.fs.normalize(wait_path)
    local normalized_dir = vim.fs.normalize(action_dir)

    if vim.fs.dirname(normalized_path) ~= normalized_dir then
        return nil
    end

    local basename = vim.fs.basename(normalized_path)

    if basename == nil or basename:match('^[0-9]+%.[0-9]+$') == nil then
        return nil
    end

    if not regular_directory(normalized_dir) then
        return nil
    end

    return vim.fs.joinpath(normalized_dir, basename)
end

---@param terminal terminalia.TerminalRecord
---@param payload table
---@param status 'ok'|'error'
local function complete_terminal_action_wait(terminal, payload, status)
    if type(payload.wait) ~= 'table' or payload.wait.kind ~= 'file' or type(payload.wait.path) ~= 'string' then
        return
    end

    local paths = launch_action_wait_dirs[terminal.id]

    if type(paths) ~= 'table' then
        return
    end

    for _, path in ipairs(paths) do
        local safe_path = type(path) == 'string' and path ~= '' and wait_token_path(payload.wait.path, path)

        if safe_path ~= nil then
            local fd = vim.uv.fs_open(safe_path, 'wx', 384)

            if fd == nil then
                return
            end

            pcall(vim.uv.fs_write, fd, status .. '\n', -1)
            pcall(vim.uv.fs_close, fd)
            return
        end
    end
end

---@param targets terminalia.ExternalOpenTarget[]
---@return integer[]
local function target_buffers(targets)
    local bufnrs = {}
    local seen = {}

    for _, target in ipairs(targets or {}) do
        local bufnr

        if type(target.path) == 'string' and target.path ~= '' then
            bufnr = vim.fn.bufnr(target.path)
        elseif target.stdin then
            bufnr = vim.api.nvim_get_current_buf()
        end

        if type(bufnr) == 'number' and bufnr > 0 and not seen[bufnr] and vim.api.nvim_buf_is_valid(bufnr) then
            seen[bufnr] = true
            table.insert(bufnrs, bufnr)
        end
    end

    return bufnrs
end

---@param bufnr integer
---@return boolean
local function buffer_visible(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
        return false
    end

    for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
        for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
            if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
                return true
            end
        end
    end

    return false
end

---@param targets terminalia.ExternalOpenTarget[]
---@param complete fun(status: 'ok'|'error')
local function complete_when_targets_close(targets, complete)
    local bufnrs = target_buffers(targets)

    if #bufnrs == 0 then
        complete('ok')
        return
    end

    local group = vim.api.nvim_create_augroup('terminalia-action-wait-' .. vim.uv.hrtime(), {
        clear = true,
    })

    local function check_done()
        for _, bufnr in ipairs(bufnrs) do
            if buffer_visible(bufnr) then
                return
            end
        end

        pcall(vim.api.nvim_del_augroup_by_id, group)
        complete('ok')
    end

    for _, bufnr in ipairs(bufnrs) do
        vim.api.nvim_create_autocmd({ 'BufDelete', 'BufUnload', 'BufWipeout', 'BufWinLeave' }, {
            group = group,
            buffer = bufnr,
            desc = 'Complete Terminalia editor wait token when opened target closes',
            callback = function()
                vim.schedule(check_done)
            end,
        })
    end

    check_done()
end

---@return table<string, string>
local function current_environment()
    local env = {}

    for name, value in pairs(vim.fn.environ()) do
        env[name] = value
    end

    return env
end

---@param command string|string[]
---@return boolean
local function supports_shell_cwd_fallback(command)
    if type(command) == 'string' then
        return false
    end

    if type(command) ~= 'table' or type(command[1]) ~= 'string' then
        return false
    end

    if #command == 1 then
        return false
    end

    local executable = vim.fs.basename(command[1])

    return executable == 'sh' or executable == 'bash' or executable == 'zsh'
end

---@param command string|string[]
---@return string|string[]
local function with_shell_cwd_fallback(command)
    if config.get().emit_cwd_fallback_marker ~= true or not supports_shell_cwd_fallback(command) then
        return command
    end

    local marker = 'printf \'__TERMINALIA_CWD__=%s\\n\' "$PWD"'

    if type(command) == 'string' then
        return string.format('%s -lc %q', command, marker .. '; exec "$SHELL" -i')
    end

    local wrapped = vim.deepcopy(command)
    local command_string = table.concat(vim.list_slice(wrapped, 2), ' ')

    if command_string == '' then
        wrapped[2] = '-lc'
        wrapped[3] = marker .. '; exec "$SHELL" -i'
        return wrapped
    end

    if wrapped[2] == '-lc' or wrapped[2] == '-c' then
        wrapped[3] = marker .. '; ' .. (wrapped[3] or '')
        return wrapped
    end

    return command
end

---@param terminal terminalia.TerminalRecord
---@return table<string, string>?
local function resolve_environment(terminal)
    if terminal.env == nil then
        return nil
    end

    return vim.tbl_extend('force', current_environment(), terminal.env)
end

---@param env table<string, string>?
---@return table<string, string>?
local function nil_if_empty_env(env)
    if type(env) ~= 'table' or next(env) == nil then
        return nil
    end

    return env
end

---@param sequence string
---@return string?
local function parse_osc7_directory(sequence)
    local uri = sequence:match('^\027%]7;([^\027\007]+)')

    if uri == nil then
        return nil
    end

    local ok, directory = pcall(vim.uri_to_fname, uri)

    if not ok or vim.fn.isdirectory(directory) == 0 then
        return nil
    end

    return directory
end

---@param line string
---@return string?
local function parse_cwd_fallback_line(line)
    if type(line) ~= 'string' or not vim.startswith(line, cwd_fallback_prefix) then
        return nil
    end

    local directory = line:sub(#cwd_fallback_prefix + 1):match('^[^\r\n]*')

    if directory == '' or vim.fn.isdirectory(directory) == 0 then
        return nil
    end

    return directory
end

---@param chunk string
---@return string?
local function strip_cwd_fallback_chunk(chunk)
    if type(chunk) ~= 'string' or not vim.startswith(chunk, cwd_fallback_prefix) then
        return chunk
    end

    local line_end = chunk:find('[\r\n]')

    if line_end == nil then
        return ''
    end

    while line_end <= #chunk do
        local char = chunk:sub(line_end, line_end)

        if char ~= '\r' and char ~= '\n' then
            break
        end

        line_end = line_end + 1
    end

    return chunk:sub(line_end)
end

---@param terminal_id string
---@param data string[]?
local function apply_cwd_fallback_chunks(terminal_id, data)
    if type(data) ~= 'table' or registry.get(terminal_id) == nil then
        return
    end

    for _, chunk in ipairs(data) do
        local directory = parse_cwd_fallback_line(chunk)

        if directory ~= nil then
            registry.update(terminal_id, {
                cwd = directory,
            })
        end
    end
end

---@param data string[]?
---@return string[]?
local function strip_cwd_fallback_chunks(data)
    if type(data) ~= 'table' then
        return data
    end

    local filtered = {}

    for _, chunk in ipairs(data) do
        local stripped = strip_cwd_fallback_chunk(chunk)

        if stripped ~= '' then
            table.insert(filtered, stripped)
        end
    end

    return filtered
end

---@param terminal terminalia.TerminalRecord
---@param action terminalia.TerminalAction
local function open_terminalia_action(terminal, action)
    local payload = vim.deepcopy(action.payload or {})

    if action.kind ~= 'open' then
        return
    end

    payload.cwd = payload.cwd or terminal.cwd

    vim.schedule(function()
        local wait_completed = false
        local has_wait = type(payload.wait) == 'table'

        local function complete_wait(status)
            if wait_completed then
                return
            end

            wait_completed = true
            complete_terminal_action_wait(terminal, payload, status)
        end

        local ok, err = pcall(function()
            local api = require('terminalia.api')
            local plan = api.plan_external_open(payload.argv or {}, {
                cwd = payload.cwd,
                open_policy = payload.open_policy,
            })

            if
                git_tool_relay.try_open(plan, payload, {
                    stdin_data = payload.stdin_data,
                    on_complete = has_wait and complete_wait or nil,
                })
            then
                return
            end

            if #(plan.pre_commands or {}) > 0 or #(plan.commands or {}) > 0 then
                error('Terminalia terminal actions cannot execute editor commands')
            end

            local opened_targets = require('terminalia.relay.open').open_plan(plan, {
                stdin_data = payload.stdin_data,
            })

            if has_wait then
                complete_when_targets_close(opened_targets, complete_wait)
            end
        end)

        if not ok then
            complete_wait('error')
            vim.notify(string.format('Terminalia terminal action failed: %s', err), vim.log.levels.ERROR)
        end
    end)
end

---@param terminal terminalia.TerminalRecord
---@param sequence string
local function handle_terminalia_action_sequence(terminal, sequence)
    local action = action_protocol.parse_sequence(sequence)

    if action == nil then
        return
    end

    local context = contexts.get(terminal.context_id)

    if context ~= nil then
        local ok, transformed = pcall(context_providers.transform_terminal_action, context, action, terminal)

        if not ok then
            vim.notify(
                string.format('Terminalia terminal action transform failed: %s', transformed),
                vim.log.levels.ERROR
            )
            return
        end

        if transformed == false then
            return
        end

        action = transformed or action
    end

    open_terminalia_action(terminal, action)
end

---@param terminal_id string
local function clear_action_strip_state(terminal_id)
    action_strip_state[terminal_id] = nil
end

---@param launch terminalia.PreparedShellLaunch?
local function cleanup_launch(launch)
    if type(launch) ~= 'table' or type(launch.cleanup_paths) ~= 'table' then
        return
    end

    for _, path in ipairs(launch.cleanup_paths) do
        if type(path) == 'string' and path ~= '' then
            pcall(vim.fn.delete, path, 'rf')
        end
    end

    launch.cleanup_paths = nil
end

---@param terminal_id string
local function cleanup_launch_paths(terminal_id)
    local paths = launch_cleanup_paths[terminal_id]
    launch_action_wait_dirs[terminal_id] = nil

    if type(paths) ~= 'table' then
        return
    end

    launch_cleanup_paths[terminal_id] = nil
    cleanup_launch({
        cleanup_paths = paths,
    })
end

---@param terminal_id string
---@param stream_name string
---@return terminalia.TerminalActionStripState
local function action_strip_state_for(terminal_id, stream_name)
    action_strip_state[terminal_id] = action_strip_state[terminal_id] or {}
    action_strip_state[terminal_id][stream_name] = action_strip_state[terminal_id][stream_name]
        or action_protocol.new_strip_state()

    return action_strip_state[terminal_id][stream_name]
end

---Register runtime autocmds once.
function M.ensure_autocmds()
    if autocmds_registered then
        return
    end

    local group = vim.api.nvim_create_augroup('terminalia-runtime', {
        clear = true,
    })

    vim.api.nvim_create_autocmd('TermRequest', {
        group = group,
        desc = 'Update Terminalia cwd metadata from OSC 7 requests',
        callback = function(event)
            local terminal_id = vim.b[event.buf].terminalia_id

            if terminal_id == nil then
                return
            end

            if type(event.data) ~= 'table' or type(event.data.sequence) ~= 'string' then
                return
            end

            local directory = parse_osc7_directory(event.data.sequence)

            if directory == nil or registry.get(terminal_id) == nil then
                local terminal = registry.get(terminal_id)

                if terminal ~= nil then
                    handle_terminalia_action_sequence(terminal, event.data.sequence)
                end

                return
            end

            registry.update(terminal_id, {
                cwd = directory,
            })
        end,
    })

    autocmds_registered = true
end

---@param terminal terminalia.TerminalRecord
---@return terminalia.PreparedShellLaunch
local function resolve_launch(terminal)
    local cfg = config.get()
    local prepared = shell_integration.prepare_launch(terminal.command or cfg.shell, {
        commands = cfg.editor_shell_commands,
        enabled = cfg.enable_editor_shell_integration,
        env = resolve_environment(terminal),
        open_policy = cfg.external_open_policy,
    })

    prepared.command = with_shell_cwd_fallback(prepared.command)
    prepared.env = parent_redirect.extend_child_env(prepared.env, {
        open_policy = cfg.external_open_policy,
    })
    prepared.env = nil_if_empty_env(prepared.env)

    return prepared
end

local buffer_runtime_state = {
    buffer_state = buffer_state,
    hidden_startup_scratch_bufnr = nil,
    hidden_startup_tabpage = nil,
    hidden_startup_window = nil,
}

buffer_helper = buffer_helpers.new(buffer_runtime_state, {
    config = config,
    registry = registry,
    uri = uri,
})

visible_windows_for_buffer = buffer_helper.visible_windows_for_buffer

output_helper = output_helpers.new({
    captured_output = captured_output,
    pending_output = pending_output,
    exited_disposables = exited_disposables,
    pending_disposable_cleanup = pending_disposable_cleanup,
    disposable_bufnrs = disposable_bufnrs,
}, {
    history = history,
    registry = registry,
    visible_windows_for_buffer = visible_windows_for_buffer,
})

---Start the native terminal job if it is not already running.
---@param terminal terminalia.TerminalRecord
---@return terminalia.TerminalRecord
function M.ensure_started(terminal)
    local current = assert(registry.get(terminal.id), string.format('Unknown terminal id: %s', terminal.id))

    if
        current.job_id
        and current.status == 'running'
        and current.bufnr
        and vim.api.nvim_buf_is_valid(current.bufnr)
    then
        return current
    end

    if current.status == 'exited' then
        M.clear_output(current.id)
    end

    current = registry.update(current.id, {
        job_id = vim.NIL,
    })

    local commit_restarted_buffer
    local bufnr

    if current.status == 'exited' then
        bufnr, commit_restarted_buffer = buffer_helper.prepare_restarted_terminal_buffer(current)
    else
        bufnr = buffer_helper.ensure_buffer(current)
    end

    current = assert(registry.get(current.id), string.format('Unknown terminal id: %s', current.id))
    buffer_helper.restore_buffer_state(current, bufnr)

    if current.status ~= 'exited' then
        buffer_state[current.id] = nil
    end
    local job_id
    local start_generation = session_generation
    local launch

    job_id = buffer_helper.with_hidden_terminal_window(bufnr, function()
        local start_terminal = assert(registry.get(current.id), string.format('Unknown terminal id: %s', current.id))

        launch = resolve_launch(start_terminal)

        if type(launch.cleanup_paths) == 'table' then
            launch_cleanup_paths[start_terminal.id] = vim.deepcopy(launch.cleanup_paths)
            launch_action_wait_dirs[start_terminal.id] = vim.tbl_map(function(path)
                return vim.fs.joinpath(path, 'actions')
            end, launch.cleanup_paths)
        else
            launch_cleanup_paths[start_terminal.id] = nil
            launch_action_wait_dirs[start_terminal.id] = nil
        end

        local started_job_id = vim.fn.termopen(launch.command, {
            cwd = start_terminal.cwd,
            env = launch.env,
            on_stdout = function(_, data)
                if start_generation ~= session_generation then
                    return
                end

                apply_cwd_fallback_chunks(start_terminal.id, data)
                data = strip_cwd_fallback_chunks(data)
                data = action_protocol.strip_action_chunks(data, action_strip_state_for(start_terminal.id, 'stdout'))
                if config.get().persist_history ~= true then
                    output_helper.append_output(start_terminal.id, data)
                end
                history.append_chunks(start_terminal.id, data)
            end,
            on_stderr = function(_, data)
                if start_generation ~= session_generation then
                    return
                end

                apply_cwd_fallback_chunks(start_terminal.id, data)
                data = strip_cwd_fallback_chunks(data)
                data = action_protocol.strip_action_chunks(data, action_strip_state_for(start_terminal.id, 'stderr'))
                if config.get().persist_history ~= true then
                    output_helper.append_output(start_terminal.id, data)
                end
                history.append_chunks(start_terminal.id, data)
            end,
            on_exit = function(_, exit_code)
                cleanup_launch(launch)

                if start_generation ~= session_generation then
                    return
                end

                local exited_terminal = registry.get(start_terminal.id)

                history.flush(start_terminal.id)
                cleanup_launch_paths(start_terminal.id)

                if not exited_terminal then
                    return
                end

                if exited_terminal.disposable then
                    local exited = registry.update(exited_terminal.id, {
                        status = 'exited',
                        exit_code = exit_code,
                        job_id = vim.NIL,
                    })

                    if exited then
                        exited_disposables[exited_terminal.id] = vim.deepcopy(exited)
                        disposable_bufnrs[exited_terminal.id] = exited.bufnr
                    end

                    if config.get().notify_on_exit then
                        vim.schedule(function()
                            vim.notify(string.format('Terminal %s exited with code %d', start_terminal.id, exit_code))
                        end)
                    end

                    registry.remove(exited_terminal.id, { wipe_buffer = false, clear_history = false })
                    clear_action_strip_state(exited_terminal.id)
                    pending_disposable_cleanup[exited_terminal.id] = true
                    return
                end

                if config.get().notify_on_exit then
                    vim.schedule(function()
                        vim.notify(string.format('Terminal %s exited with code %d', start_terminal.id, exit_code))
                    end)
                end

                registry.update(exited_terminal.id, {
                    status = 'exited',
                    exit_code = exit_code,
                    job_id = vim.NIL,
                })
            end,
        })

        return started_job_id
    end)

    if not job_id or job_id <= 0 then
        if commit_restarted_buffer ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end

        cleanup_launch(launch)
        cleanup_launch_paths(current.id)
        error(string.format('Failed to start terminal %s', current.id))
    end

    if commit_restarted_buffer ~= nil then
        bufnr = commit_restarted_buffer()
    end

    current = assert(registry.get(current.id), string.format('Unknown terminal id: %s', current.id))
    if current.bufnr ~= nil and vim.api.nvim_buf_is_valid(current.bufnr) then
        buffer_helper.set_terminal_buffer_name(current.bufnr, current)
    elseif vim.api.nvim_buf_is_valid(bufnr) then
        buffer_helper.set_terminal_buffer_name(bufnr, current)
    end

    return registry.update(current.id, {
        bufnr = current.bufnr or bufnr,
        job_id = job_id,
        status = 'running',
        exit_code = vim.NIL,
    })
end
---@param id string
---@param opts? { bufnr?: integer, event?: string }
---Write stdin data into a running terminal job, starting it first if needed.
---@param terminal terminalia.TerminalRecord
---@param data string
---@return terminalia.TerminalRecord
function M.send(terminal, data)
    local current = M.ensure_started(terminal)

    assert(current.job_id ~= nil, string.format('Terminal %s has no running job', terminal.id))
    vim.fn.chansend(current.job_id, data)

    return current
end

---Wait for a running terminal job to exit.
---@param terminal terminalia.TerminalRecord
---@param timeout_ms? integer
---@return terminalia.TerminalRecord?
function M.wait_for_exit(terminal, timeout_ms)
    local current = registry.get(terminal.id)

    if current == nil and exited_disposables[terminal.id] == nil then
        error(string.format('Unknown terminal id: %s', terminal.id))
    end

    if current == nil then
        local exited = exited_disposables[terminal.id]

        if exited == nil then
            return nil
        end

        local bufnr = exited.bufnr or disposable_bufnrs[terminal.id]

        if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) and #visible_windows_for_buffer(bufnr) > 0 then
            return nil
        end

        return exited
    end

    if current.status ~= 'running' or current.job_id == nil then
        if current.disposable and current.status == 'exited' and output_helper.finalize_disposable(current.id) then
            registry.remove(current.id, { wipe_buffer = false, clear_history = false })
        end
        return current
    end

    local results = vim.fn.jobwait({ current.job_id }, timeout_ms == nil and -1 or timeout_ms)
    local exit_code = results[1]

    if exit_code == -1 then
        return nil
    end

    current = registry.get(terminal.id)

    if current == nil then
        current = exited_disposables[terminal.id]

        if current == nil then
            return nil
        end

        current.status = 'exited'
        current.exit_code = exit_code
        current.job_id = vim.NIL
    elseif current.status ~= 'exited' then
        history.flush(terminal.id)
        current = registry.update(terminal.id, {
            status = 'exited',
            exit_code = exit_code,
            job_id = vim.NIL,
        })
    end

    if current == nil then
        return nil
    end

    return current
end

---Request termination of a running terminal job.
---@param terminal terminalia.TerminalRecord
---@return terminalia.TerminalRecord
function M.kill(terminal)
    local current = assert(registry.get(terminal.id), string.format('Unknown terminal id: %s', terminal.id))

    if current.status == 'running' and current.job_id ~= nil then
        vim.fn.jobstop(current.job_id)
    end

    return current
end

---Return the current live output snapshot for a terminal, if any.
---@param id string
---@return string, boolean
function M.output(id)
    return output_helper.output(id)
end

---@param id string
---@return terminalia.TerminalRecord?
function M.exited_terminal(id)
    return output_helper.exited_terminal(id)
end

---@param id string
function M.forget_exited_terminal(id)
    output_helper.forget_exited_terminal(id)
    clear_action_strip_state(id)
end

---@param id string
---@return terminalia.TerminalRecord?
function M.release_exited_terminal(id)
    local released = output_helper.release_exited_terminal(id)

    clear_action_strip_state(id)

    return released
end

---Clear live output state for a terminal.
---@param id string
function M.clear_output(id)
    output_helper.clear_output(id)
    clear_action_strip_state(id)
end

---Clear all live runtime output state.
function M.clear()
    session_generation = session_generation + 1

    for _, terminal in ipairs(registry.list()) do
        if terminal.status == 'running' and terminal.job_id ~= nil then
            pcall(vim.fn.jobstop, terminal.job_id)
        end
    end

    for id in pairs(pending_disposable_cleanup) do
        history.clear(id)
    end

    for key in pairs(captured_output) do
        captured_output[key] = nil
    end
    for key in pairs(pending_output) do
        pending_output[key] = nil
    end
    for key in pairs(exited_disposables) do
        exited_disposables[key] = nil
    end
    for key in pairs(pending_disposable_cleanup) do
        pending_disposable_cleanup[key] = nil
    end
    for key in pairs(disposable_bufnrs) do
        disposable_bufnrs[key] = nil
    end
    for key in pairs(buffer_state) do
        buffer_state[key] = nil
    end
    for key in pairs(action_strip_state) do
        action_strip_state[key] = nil
    end
    for key in pairs(launch_cleanup_paths) do
        cleanup_launch_paths(key)
    end
    buffer_helper.cleanup_hidden_startup_window()
end

---@param terminal_id string
---@param data string[]?
function M._apply_cwd_fallback_chunks(terminal_id, data)
    apply_cwd_fallback_chunks(terminal_id, data)
end

---@param data string[]?
---@return string[]?
function M._strip_cwd_fallback_chunks(data)
    return strip_cwd_fallback_chunks(data)
end

---@param command string|string[]
---@return string|string[]
function M._resolve_command_with_fallback(command)
    return with_shell_cwd_fallback(command)
end

---@param command string|string[]
---@return terminalia.PreparedShellLaunch
function M._resolve_launch(command)
    return resolve_launch({
        command = command,
        cwd = vim.fn.getcwd(),
        id = 'terminalia:test',
        name = 'terminalia:test',
        namespace = 'test',
        context_id = 'context:host',
        disposable = false,
        status = 'registered',
        preferred_view = 'split',
        created_at = os.time(),
    })
end

vim.api.nvim_create_autocmd({ 'BufHidden', 'BufWipeout', 'WinClosed' }, {
    group = disposable_cleanup_group,
    callback = function(event)
        local bufnr = event.buffer or event.buf

        if bufnr == nil and event.match ~= nil then
            bufnr = tonumber(event.match)
        end

        if bufnr == nil then
            return
        end

        for id, pending in pairs(pending_disposable_cleanup) do
            if pending == true then
                local finalized = output_helper.finalize_disposable(id, {
                    bufnr = bufnr,
                    event = event.event,
                })

                if finalized then
                    clear_action_strip_state(id)
                end
            end
        end
    end,
})

return M

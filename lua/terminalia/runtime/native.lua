local config = require('terminalia.config')
local history = require('terminalia.history')
local buffer_helpers = require('terminalia.runtime.buffer')
local registry = require('terminalia.terminal.registry')
local output_helpers = require('terminalia.runtime.output')
local uri = require('terminalia.uri')

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

local disposable_cleanup_group = vim.api.nvim_create_augroup('terminal-manager-disposable-cleanup', {
    clear = true,
})

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
        return command == vim.o.shell
    end

    if type(command) ~= 'table' or type(command[1]) ~= 'string' then
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

    local directory = line:sub(#cwd_fallback_prefix + 1)

    if directory == '' or vim.fn.isdirectory(directory) == 0 then
        return nil
    end

    return directory
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
        if parse_cwd_fallback_line(chunk) == nil then
            table.insert(filtered, chunk)
        end
    end

    return filtered
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
---@return string|string[]
local function resolve_command(terminal)
    return with_shell_cwd_fallback(terminal.command or config.get().shell)
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

    job_id = buffer_helper.with_hidden_terminal_window(bufnr, function()
        local start_terminal = assert(registry.get(current.id), string.format('Unknown terminal id: %s', current.id))

        return vim.fn.termopen(resolve_command(start_terminal), {
            cwd = start_terminal.cwd,
            env = resolve_environment(start_terminal),
            on_stdout = function(_, data)
                if start_generation ~= session_generation then
                    return
                end

                apply_cwd_fallback_chunks(start_terminal.id, data)
                data = strip_cwd_fallback_chunks(data)
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
                if config.get().persist_history ~= true then
                    output_helper.append_output(start_terminal.id, data)
                end
                history.append_chunks(start_terminal.id, data)
            end,
            on_exit = function(_, exit_code)
                if start_generation ~= session_generation then
                    return
                end

                local exited_terminal = registry.get(start_terminal.id)

                history.flush(start_terminal.id)

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
    end)

    if not job_id or job_id <= 0 then
        if commit_restarted_buffer ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end

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
end

---@param id string
---@return terminalia.TerminalRecord?
function M.release_exited_terminal(id)
    return output_helper.release_exited_terminal(id)
end

---Clear live output state for a terminal.
---@param id string
function M.clear_output(id)
    output_helper.clear_output(id)
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
    buffer_helper.cleanup_hidden_startup_window()
end

---@param terminal_id string
---@param data string[]?
function M._apply_cwd_fallback_chunks(terminal_id, data)
    apply_cwd_fallback_chunks(terminal_id, data)
end

---@param command string|string[]
---@return string|string[]
function M._resolve_command_with_fallback(command)
    return with_shell_cwd_fallback(command)
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
                output_helper.finalize_disposable(id, {
                    bufnr = bufnr,
                    event = event.event,
                })
            end
        end
    end,
})

return M

local config = require('terminalia.config')
local history = require('terminalia.history')
local registry = require('terminalia.terminal.registry')
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

---@param terminal terminalia.TerminalRecord
---@return string
local function terminal_buffer_name(terminal)
    return uri.encode_terminal_uri(terminal)
end

---@param terminal terminalia.TerminalRecord
---@param bufnr integer
---@return string
local function displaced_terminal_buffer_name(terminal, bufnr)
    return string.format('terminalia-displaced://%s/%d', terminal.id, bufnr)
end

---@param target_name string
---@param owner_bufnr integer
---@param terminal terminalia.TerminalRecord
local function displace_conflicting_buffer(target_name, owner_bufnr, terminal)
    local existing = vim.fn.bufnr(target_name)

    if existing <= 0 or existing == owner_bufnr or not vim.api.nvim_buf_is_valid(existing) then
        return
    end

    pcall(vim.api.nvim_buf_set_name, existing, displaced_terminal_buffer_name(terminal, existing))
end

---@param bufnr integer
---@param terminal terminalia.TerminalRecord
local function set_terminal_buffer_name(bufnr, terminal)
    local target_name = terminal_buffer_name(terminal)
    displace_conflicting_buffer(target_name, bufnr, terminal)
    vim.api.nvim_buf_set_name(bufnr, target_name)
end

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

---@param id string
---@param data? string[]
local function append_output(id, data)
    if data == nil or #data == 0 then
        return
    end

    local tail = pending_output[id] or ''
    local pieces = {}

    for index, chunk in ipairs(data) do
        local value = chunk

        if index == 1 then
            value = tail .. value
        end

        if index == #data then
            pending_output[id] = value
        else
            table.insert(pieces, value)
        end
    end

    if #pieces == 0 then
        return
    end

    local text = table.concat(pieces, '\n') .. '\n'
    captured_output[id] = (captured_output[id] or '') .. text
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
            local terminal_id = vim.b[event.buf].terminal_manager_id

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
    return terminal.command or config.get().shell
end

---@param id string
---@return terminalia.TerminalRecord?
local function current_terminal(id)
    return registry.get(id) or exited_disposables[id]
end

---@param listed boolean
---@return integer
local function create_runtime_buffer(listed)
    local bufnr = vim.api.nvim_create_buf(listed, false)

    if vim.bo[bufnr].buftype == 'nofile' then
        vim.bo[bufnr].buftype = ''
    end

    return bufnr
end

---@param terminal terminalia.TerminalRecord
---@return integer
local function ensure_buffer(terminal)
    if terminal.bufnr and vim.api.nvim_buf_is_valid(terminal.bufnr) then
        return terminal.bufnr
    end

    local bufnr = create_runtime_buffer(false)

    vim.bo[bufnr].bufhidden = 'hide'
    vim.bo[bufnr].swapfile = false
    set_terminal_buffer_name(bufnr, terminal)
    vim.b[bufnr].terminal_manager_id = terminal.id

    registry.update(terminal.id, {
        bufnr = bufnr,
    })

    return bufnr
end

---@param bufnr integer
---@return table<string, integer[]>
local function capture_named_marks(bufnr)
    local marks = {}

    for code = string.byte('a'), string.byte('z') do
        local name = string.char(code)
        local mark = vim.api.nvim_buf_get_mark(bufnr, name)

        if mark[1] > 0 then
            marks[name] = mark
        end
    end

    return marks
end

---@param terminal terminalia.TerminalRecord
local function capture_buffer_state(terminal)
    local bufnr = terminal.bufnr

    if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
        buffer_state[terminal.id] = nil
        return
    end

    buffer_state[terminal.id] = {
        marks = capture_named_marks(bufnr),
    }
end

---@param terminal terminalia.TerminalRecord
---@return integer, fun(): integer
local function prepare_restarted_terminal_buffer(terminal)
    capture_buffer_state(terminal)

    local original_bufnr = terminal.bufnr
    local replacement_bufnr = create_runtime_buffer(false)

    if replacement_bufnr == 0 then
        error(string.format('Failed to create buffer for terminal %s', terminal.id))
    end

    vim.bo[replacement_bufnr].bufhidden = 'hide'
    vim.bo[replacement_bufnr].swapfile = false
    set_terminal_buffer_name(replacement_bufnr, terminal)
    vim.b[replacement_bufnr].terminal_manager_id = terminal.id

    local function commit()
        local updated = registry.update(terminal.id, {
            bufnr = replacement_bufnr,
        })

        if original_bufnr and vim.api.nvim_buf_is_valid(original_bufnr) then
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(original_bufnr) then
                    pcall(vim.api.nvim_buf_delete, original_bufnr, { force = true })
                end
            end)
        end

        return updated.bufnr or replacement_bufnr
    end

    return replacement_bufnr, commit
end

---@param terminal terminalia.TerminalRecord
---@param bufnr integer
local function restore_buffer_state(terminal, bufnr)
    local state = buffer_state[terminal.id]

    if state == nil then
        return
    end

    for mark, position in pairs(state.marks or {}) do
        pcall(vim.api.nvim_buf_set_mark, bufnr, mark, position[1], position[2], {})
    end

    buffer_state[terminal.id] = nil
end

local hidden_terminal_events = { 'BufEnter', 'BufLeave' }
local hidden_startup_tabpage
local hidden_startup_window
local hidden_startup_scratch_bufnr

---@param eventignore string
---@return string
local function add_hidden_terminal_events(eventignore)
    local seen = {}
    local events = {}

    for event in string.gmatch(eventignore, '[^,]+') do
        if not seen[event] then
            seen[event] = true
            events[#events + 1] = event
        end
    end

    for _, event in ipairs(hidden_terminal_events) do
        if not seen[event] then
            events[#events + 1] = event
        end
    end

    return table.concat(events, ',')
end

---@return integer
local function ensure_hidden_startup_window()
    if hidden_startup_window ~= nil and vim.api.nvim_win_is_valid(hidden_startup_window) then
        return hidden_startup_window
    end

    local previous_tabpage = vim.api.nvim_get_current_tabpage()
    local previous_winid = vim.api.nvim_get_current_win()
    local previous_ei = vim.o.eventignore

    vim.o.eventignore = add_hidden_terminal_events(previous_ei)
    vim.cmd('silent keepalt noautocmd tabnew')

    hidden_startup_tabpage = vim.api.nvim_get_current_tabpage()
    hidden_startup_window = vim.api.nvim_get_current_win()

    pcall(vim.api.nvim_set_current_tabpage, previous_tabpage)
    pcall(vim.api.nvim_set_current_win, previous_winid)
    vim.o.eventignore = previous_ei

    return hidden_startup_window
end

---@return integer
local function ensure_hidden_startup_scratch_buffer()
    if hidden_startup_scratch_bufnr ~= nil and vim.api.nvim_buf_is_valid(hidden_startup_scratch_bufnr) then
        return hidden_startup_scratch_bufnr
    end

    hidden_startup_scratch_bufnr = vim.api.nvim_create_buf(false, true)

    return hidden_startup_scratch_bufnr
end

local function cleanup_hidden_startup_window()
    if hidden_startup_window ~= nil and vim.api.nvim_win_is_valid(hidden_startup_window) then
        pcall(vim.api.nvim_win_set_buf, hidden_startup_window, ensure_hidden_startup_scratch_buffer())
    end

    if hidden_startup_tabpage ~= nil and vim.api.nvim_tabpage_is_valid(hidden_startup_tabpage) then
        pcall(vim.api.nvim_tabpage_close, hidden_startup_tabpage, true)
    end

    hidden_startup_tabpage = nil
    hidden_startup_window = nil
end

---@param bufnr integer
---@return integer[]
local function visible_windows_for_buffer(bufnr)
    local wins = vim.fn.win_findbuf(bufnr)

    if wins == nil or #wins == 0 then
        return {}
    end

    return vim.tbl_filter(function(winid)
        return hidden_startup_window == nil or winid ~= hidden_startup_window
    end, wins)
end

---@param bufnr integer
---@param callback fun(): integer
---@return integer
local function with_hidden_terminal_window(bufnr, callback)
    local previous_ei = vim.o.eventignore
    local previous_tabpage = vim.api.nvim_get_current_tabpage()
    local previous_winid = vim.api.nvim_get_current_win()
    local hidden_winid = ensure_hidden_startup_window()

    local ok, result = xpcall(function()
        vim.o.eventignore = add_hidden_terminal_events(previous_ei)
        vim.api.nvim_set_current_win(hidden_winid)
        vim.api.nvim_win_set_buf(hidden_winid, bufnr)
        return callback()
    end, debug.traceback)

    pcall(vim.api.nvim_set_current_tabpage, previous_tabpage)
    pcall(vim.api.nvim_set_current_win, previous_winid)
    cleanup_hidden_startup_window()
    vim.o.eventignore = previous_ei

    if not ok then
        error(result)
    end

    return result
end

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
        bufnr, commit_restarted_buffer = prepare_restarted_terminal_buffer(current)
    else
        bufnr = ensure_buffer(current)
    end

    current = assert(registry.get(current.id), string.format('Unknown terminal id: %s', current.id))
    restore_buffer_state(current, bufnr)

    if current.status ~= 'exited' then
        buffer_state[current.id] = nil
    end
    local job_id
    local start_generation = session_generation

    job_id = with_hidden_terminal_window(bufnr, function()
        local start_terminal = assert(registry.get(current.id), string.format('Unknown terminal id: %s', current.id))

        return vim.fn.termopen(resolve_command(start_terminal), {
            cwd = start_terminal.cwd,
            env = resolve_environment(start_terminal),
            on_stdout = function(_, data)
                if start_generation ~= session_generation then
                    return
                end

                if config.get().persist_history ~= true then
                    append_output(start_terminal.id, data)
                end
                history.append_chunks(start_terminal.id, data)
            end,
            on_stderr = function(_, data)
                if start_generation ~= session_generation then
                    return
                end

                if config.get().persist_history ~= true then
                    append_output(start_terminal.id, data)
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
        set_terminal_buffer_name(current.bufnr, current)
    elseif vim.api.nvim_buf_is_valid(bufnr) then
        set_terminal_buffer_name(bufnr, current)
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
local function finalize_disposable(id, opts)
    if pending_disposable_cleanup[id] ~= true then
        return false
    end

    local terminal = exited_disposables[id]
    local bufnr = terminal and terminal.bufnr or disposable_bufnrs[id]
    local target_bufnr = opts and opts.bufnr or nil

    if target_bufnr ~= nil and bufnr ~= nil and target_bufnr ~= bufnr then
        return false
    end

    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        local wins = visible_windows_for_buffer(bufnr)
        if #wins > 0 then
            return false
        end

        if opts and opts.event == 'WinClosed' then
            vim.schedule(function()
                finalize_disposable(id, { bufnr = bufnr })
            end)
            return false
        end

        if opts and opts.event == 'BufWipeout' then
            vim.schedule(function()
                finalize_disposable(id, { bufnr = bufnr })
            end)
            return false
        end

        if opts and opts.event == 'BufHidden' then
            local post_hide_wins = visible_windows_for_buffer(bufnr)
            if #post_hide_wins > 0 then
                vim.schedule(function()
                    finalize_disposable(id, { bufnr = bufnr })
                end)
                return false
            end
        end

        if bufnr == vim.api.nvim_get_current_buf() then
            vim.cmd('enew')
        end

        for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
            if vim.api.nvim_win_is_valid(winid) then
                pcall(vim.api.nvim_win_set_buf, winid, vim.api.nvim_create_buf(false, true))
            end
        end

        pending_disposable_cleanup[id] = 'finalizing'
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        if vim.api.nvim_buf_is_valid(bufnr) then
            pending_disposable_cleanup[id] = true
            return false
        end
    end

    pending_disposable_cleanup[id] = nil
    exited_disposables[id] = nil
    disposable_bufnrs[id] = nil
    history.clear(id)
    M.clear_output(id)
    return true
end

---@param bufnr integer
local function detach_buffer_from_windows(bufnr)
    if bufnr == vim.api.nvim_get_current_buf() then
        vim.cmd('enew')
    end

    for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
        if vim.api.nvim_win_is_valid(winid) then
            pcall(vim.api.nvim_win_set_buf, winid, vim.api.nvim_create_buf(false, true))
        end
    end
end

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
        if current.disposable and current.status == 'exited' and finalize_disposable(current.id) then
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
    local has_output = captured_output[id] ~= nil or pending_output[id] ~= nil
    local output = (captured_output[id] or '') .. (pending_output[id] or '')

    return output, has_output
end

---@param id string
---@return terminalia.TerminalRecord?
function M.exited_terminal(id)
    return current_terminal(id)
end

---@param id string
function M.forget_exited_terminal(id)
    pending_disposable_cleanup[id] = nil
    exited_disposables[id] = nil
    disposable_bufnrs[id] = nil
end

---@param id string
---@return terminalia.TerminalRecord?
function M.release_exited_terminal(id)
    local released = current_terminal(id)

    if released == nil then
        return nil
    end

    if not finalize_disposable(id) then
        local bufnr = released.bufnr or disposable_bufnrs[id]

        if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
            detach_buffer_from_windows(bufnr)
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end

        pending_disposable_cleanup[id] = nil
        exited_disposables[id] = nil
        disposable_bufnrs[id] = nil
        history.clear(id)
        M.clear_output(id)
    end

    return released
end

---Clear live output state for a terminal.
---@param id string
function M.clear_output(id)
    captured_output[id] = nil
    pending_output[id] = nil
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

    captured_output = {}
    pending_output = {}
    exited_disposables = {}
    pending_disposable_cleanup = {}
    disposable_bufnrs = {}
    buffer_state = {}
    cleanup_hidden_startup_window()
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
                finalize_disposable(id, {
                    bufnr = bufnr,
                    event = event.event,
                })
            end
        end
    end,
})

return M

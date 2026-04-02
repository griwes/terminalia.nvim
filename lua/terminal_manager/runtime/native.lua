local config = require('terminal_manager.config')
local history = require('terminal_manager.history')
local registry = require('terminal_manager.registry')

local M = {}
local autocmds_registered = false
---@type table<string, string>
local captured_output = {}
---@type table<string, string>
local pending_output = {}
---@type table<string, terminal_manager.TerminalRecord>
local exited_disposables = {}

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

    local group = vim.api.nvim_create_augroup('terminal-manager-runtime', {
        clear = true,
    })

    vim.api.nvim_create_autocmd('TermRequest', {
        group = group,
        desc = 'Update terminal-manager cwd metadata from OSC 7 requests',
        callback = function(event)
            local terminal_id = vim.b[event.buf].terminal_manager_id

            if terminal_id == nil then
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

---@param terminal terminal_manager.TerminalRecord
---@return string|string[]
local function resolve_command(terminal)
    return terminal.command or config.get().shell
end

---@param terminal terminal_manager.TerminalRecord
---@return integer
local function ensure_buffer(terminal)
    if terminal.bufnr and vim.api.nvim_buf_is_valid(terminal.bufnr) then
        return terminal.bufnr
    end

    local bufnr = vim.api.nvim_create_buf(true, false)

    vim.bo[bufnr].bufhidden = 'hide'
    vim.bo[bufnr].swapfile = false
    vim.api.nvim_buf_set_name(bufnr, string.format('terminal-manager://%s/%s', terminal.id, terminal.name))
    vim.b[bufnr].terminal_manager_id = terminal.id

    registry.update(terminal.id, {
        bufnr = bufnr,
    })

    return bufnr
end

---Start the native terminal job if it is not already running.
---@param terminal terminal_manager.TerminalRecord
---@return terminal_manager.TerminalRecord
function M.ensure_started(terminal)
    if
        terminal.job_id
        and terminal.status == 'running'
        and terminal.bufnr
        and vim.api.nvim_buf_is_valid(terminal.bufnr)
    then
        return terminal
    end

    if terminal.status == 'exited' then
        M.clear_output(terminal.id)
    end

    if terminal.status == 'exited' and terminal.bufnr and vim.api.nvim_buf_is_valid(terminal.bufnr) then
        pcall(vim.api.nvim_buf_delete, terminal.bufnr, { force = true })
        registry.update(terminal.id, {
            bufnr = vim.NIL,
            job_id = vim.NIL,
        })
    end

    local bufnr = ensure_buffer(terminal)
    local job_id

    vim.api.nvim_buf_call(bufnr, function()
            job_id = vim.fn.termopen(resolve_command(terminal), {
            cwd = terminal.cwd,
            env = terminal.env,
            on_stdout = function(_, data)
                if config.get().persist_history ~= true then
                    append_output(terminal.id, data)
                end
                history.append_chunks(terminal.id, data)
            end,
            on_stderr = function(_, data)
                if config.get().persist_history ~= true then
                    append_output(terminal.id, data)
                end
                history.append_chunks(terminal.id, data)
            end,
            on_exit = function(_, exit_code)
                local current = registry.get(terminal.id)

                history.flush(terminal.id)

                if not current then
                    return
                end

                if current.disposable then
                    local exited = registry.update(current.id, {
                        status = 'exited',
                        exit_code = exit_code,
                        job_id = vim.NIL,
                    })

                    if exited then
                        exited_disposables[current.id] = vim.deepcopy(exited)
                    end

                    if config.get().notify_on_exit then
                        vim.schedule(function()
                            vim.notify(string.format('Terminal %s exited with code %d', terminal.id, exit_code))
                        end)
                    end

                    registry.remove(current.id)
                    vim.defer_fn(function()
                        M.clear_output(current.id)
                        exited_disposables[current.id] = nil
                    end, 0)
                    return
                end

                if config.get().notify_on_exit then
                    vim.schedule(function()
                        vim.notify(string.format('Terminal %s exited with code %d', terminal.id, exit_code))
                    end)
                end

                registry.update(current.id, {
                    status = 'exited',
                    exit_code = exit_code,
                    job_id = vim.NIL,
                })
            end,
        })
    end)

    if not job_id or job_id <= 0 then
        error(string.format('Failed to start terminal %s', terminal.id))
    end

    return registry.update(terminal.id, {
        bufnr = bufnr,
        job_id = job_id,
        status = 'running',
        exit_code = vim.NIL,
    })
end

---Write stdin data into a running terminal job, starting it first if needed.
---@param terminal terminal_manager.TerminalRecord
---@param data string
---@return terminal_manager.TerminalRecord
function M.send(terminal, data)
    local current = M.ensure_started(terminal)

    assert(current.job_id ~= nil, string.format('Terminal %s has no running job', terminal.id))
    vim.fn.chansend(current.job_id, data)

    return current
end

---Wait for a running terminal job to exit.
---@param terminal terminal_manager.TerminalRecord
---@param timeout_ms? integer
---@return terminal_manager.TerminalRecord?
function M.wait_for_exit(terminal, timeout_ms)
    local current = registry.get(terminal.id)

    if current == nil and exited_disposables[terminal.id] == nil then
        error(string.format('Unknown terminal id: %s', terminal.id))
    end

    if current == nil then
        return exited_disposables[terminal.id]
    end

    if current.status ~= 'running' or current.job_id == nil then
        if current.disposable then
            exited_disposables[current.id] = nil
            M.clear_output(current.id)
            registry.remove(current.id)
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

    if current.disposable then
        exited_disposables[current.id] = nil
        M.clear_output(current.id)
        if registry.get(current.id) ~= nil then
            registry.remove(current.id)
        end
    end

    return current
end

---Request termination of a running terminal job.
---@param terminal terminal_manager.TerminalRecord
---@return terminal_manager.TerminalRecord
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

---Clear live output state for a terminal.
---@param id string
function M.clear_output(id)
    captured_output[id] = nil
    pending_output[id] = nil
end

---Clear all live runtime output state.
function M.clear()
    captured_output = {}
    pending_output = {}
    exited_disposables = {}
end

return M

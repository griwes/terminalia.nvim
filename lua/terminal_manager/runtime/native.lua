local config = require('terminal_manager.config')
local registry = require('terminal_manager.registry')

local M = {}

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

    local bufnr = ensure_buffer(terminal)
    local job_id

    vim.api.nvim_buf_call(bufnr, function()
        job_id = vim.fn.termopen(resolve_command(terminal), {
            cwd = terminal.cwd,
            on_exit = function(_, exit_code)
                registry.update(terminal.id, {
                    status = 'exited',
                    exit_code = exit_code,
                })

                if config.get().notify_on_exit then
                    vim.schedule(function()
                        vim.notify(string.format('Terminal %s exited with code %d', terminal.id, exit_code))
                    end)
                end
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
        exit_code = nil,
    })
end

return M

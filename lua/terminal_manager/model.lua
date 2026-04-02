---@alias terminal_manager.TerminalStatus 'registered'|'running'|'exited'
---@alias terminal_manager.TerminalCommand string|string[]

---@class terminal_manager.TerminalOutput
---@field output string
---@field status terminal_manager.TerminalStatus
---@field exit_code? integer

---@class terminal_manager.CreateOptions
---@field id string
---@field name? string
---@field namespace? string
---@field disposable? boolean
---@field cwd? string
---@field env? table<string, string>
---@field status? terminal_manager.TerminalStatus
---@field command? terminal_manager.TerminalCommand
---@field view? terminal_manager.ViewKind
---@field created_at? integer
---@field last_opened_at? integer
---@field exit_code? integer

---@class terminal_manager.PersistedTerminal
---@field id string
---@field name string
---@field namespace string
---@field disposable boolean
---@field cwd string
---@field status terminal_manager.TerminalStatus
---@field command? terminal_manager.TerminalCommand
---@field view terminal_manager.ViewKind
---@field created_at integer
---@field last_opened_at? integer
---@field exit_code? integer

---@class terminal_manager.ListFilters
---@field namespace? string
---@field cwd_prefix? string

---@class terminal_manager.TerminalRecord
---@field id string
---@field name string
---@field namespace string
---@field disposable boolean
---@field cwd string
---@field env? table<string, string>
---@field status terminal_manager.TerminalStatus
---@field command? terminal_manager.TerminalCommand
---@field preferred_view terminal_manager.ViewKind
---@field bufnr? integer
---@field job_id? integer
---@field exit_code? integer
---@field created_at integer
---@field last_opened_at? integer

local M = {}

---@param value any
---@return terminal_manager.TerminalStatus
local function normalize_status(value)
    if value == 'running' or value == 'exited' then
        return value
    end

    return 'registered'
end

---Create a normalized terminal record.
---@param opts terminal_manager.CreateOptions
---@return terminal_manager.TerminalRecord
function M.new_terminal(opts)
    local cwd = opts.cwd or vim.fn.getcwd()
    local preferred_view = opts.view or 'split'

    return {
        id = opts.id,
        name = opts.name or opts.id,
        namespace = opts.namespace or 'default',
        disposable = opts.disposable == true,
        cwd = cwd,
        env = opts.env and vim.deepcopy(opts.env) or nil,
        status = normalize_status(opts.status),
        command = opts.command,
        preferred_view = preferred_view,
        created_at = opts.created_at or os.time(),
        last_opened_at = opts.last_opened_at,
        exit_code = opts.exit_code,
    }
end

---Restore a terminal record from persisted metadata.
---@param opts terminal_manager.CreateOptions
---@return terminal_manager.TerminalRecord
function M.restore_terminal(opts)
    local terminal = M.new_terminal(opts)

    if terminal.status == 'running' then
        terminal.status = 'registered'
        terminal.exit_code = nil
    end

    return terminal
end

---Convert a terminal record into a persisted metadata table.
---@param terminal terminal_manager.TerminalRecord
---@return terminal_manager.PersistedTerminal
function M.to_persisted_record(terminal)
    return {
        id = terminal.id,
        name = terminal.name,
        namespace = terminal.namespace,
        disposable = terminal.disposable,
        cwd = terminal.cwd,
        status = terminal.status,
        command = terminal.command,
        view = terminal.preferred_view,
        created_at = terminal.created_at,
        last_opened_at = terminal.last_opened_at,
        exit_code = terminal.exit_code,
    }
end

return M

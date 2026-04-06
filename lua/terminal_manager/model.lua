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
---@field env? table<string, string>
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

local config = require('terminal_manager.config')

local M = {}

local VALID_ID_PATTERN = '^[%w:_%-]+$'

---@param id any
---@return boolean
function M.is_valid_id(id)
    return type(id) == 'string' and id:match(VALID_ID_PATTERN) ~= nil
end

---@param id any
---@return string
function M.assert_valid_id(id)
    if not M.is_valid_id(id) then
        error(string.format('Invalid terminal id: %s', vim.inspect(id)))
    end

    return id
end

---@param id any
---@return boolean
function M.is_string_id(id)
    return type(id) == 'string' and id ~= ''
end

---@param id any
---@param fallback_index? integer
---@return string
function M.normalize_restored_id(id, fallback_index)
    if M.is_valid_id(id) then
        return id
    end

    if type(fallback_index) == 'number' and fallback_index > 1 then
        return string.format('restored_terminal:%d', fallback_index)
    end

    return 'restored_terminal'
end

---@param value any
---@return terminal_manager.TerminalStatus
local function normalize_status(value)
    if value == 'running' or value == 'exited' then
        return value
    end

    return 'registered'
end

---@param env any
---@return table<string, string>?
function M.normalize_env(env)
    if type(env) ~= 'table' then
        return nil
    end

    local normalized = {}

    for key, value in pairs(env) do
        if type(key) == 'string' and type(value) == 'string' then
            normalized[key] = value
        end
    end

    if next(normalized) == nil then
        return nil
    end

    return normalized
end

---Create a normalized terminal record.
---@param opts terminal_manager.CreateOptions
---@return terminal_manager.TerminalRecord
function M.new_terminal(opts)
    M.assert_valid_id(opts.id)

    local cwd = opts.cwd or vim.fn.getcwd()
    local defaults = config.get()
    local preferred_view = opts.view or defaults.default_view

    return {
        id = opts.id,
        name = opts.name or opts.id,
        namespace = opts.namespace or defaults.default_namespace,
        disposable = opts.disposable == true,
        cwd = cwd,
        env = M.normalize_env(opts.env),
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
    assert(M.is_string_id(opts.id), string.format('Invalid terminal id: %s', vim.inspect(opts.id)))

    local restored_id = M.normalize_restored_id(opts.id, opts.restored_index)
    local terminal = M.new_terminal(vim.tbl_extend('force', opts, {
        id = restored_id,
    }))

    terminal.id = restored_id
    terminal.name = opts.name or 'restored_terminal'

    terminal.preferred_view = config.normalize_view(opts.view)

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
        env = M.normalize_env(terminal.env),
        status = terminal.status,
        command = terminal.command,
        view = terminal.preferred_view,
        created_at = terminal.created_at,
        last_opened_at = terminal.last_opened_at,
        exit_code = terminal.exit_code,
    }
end

return M

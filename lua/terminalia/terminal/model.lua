---@alias terminalia.TerminalStatus 'registered'|'running'|'exited'
---@alias terminalia.TerminalCommand string|string[]

---@class terminalia.TerminalOutput
---@field output string
---@field status terminalia.TerminalStatus
---@field exit_code? integer

---@class terminalia.CreateOptions
---@field id string
---@field name? string
---@field namespace? string
---@field context_id? string
---@field disposable? boolean
---@field cwd? string
---@field env? table<string, string>
---@field status? terminalia.TerminalStatus
---@field command? terminalia.TerminalCommand
---@field view? terminalia.ViewKind
---@field instance_id? string
---@field created_at? integer
---@field last_opened_at? integer
---@field exit_code? integer

---@class terminalia.PersistedTerminal
---@field id string
---@field name string
---@field namespace string
---@field context_id? string
---@field disposable boolean
---@field cwd string
---@field env? table<string, string>
---@field status terminalia.TerminalStatus
---@field command? terminalia.TerminalCommand
---@field view terminalia.ViewKind
---@field instance_id string
---@field created_at integer
---@field last_opened_at? integer
---@field exit_code? integer

---@class terminalia.ListFilters
---@field namespace? string
---@field cwd_prefix? string
---@field context_id? string

---@class terminalia.ContextCreateOptions
---@field id? string
---@field kind? string
---@field label? string
---@field parent_id? string
---@field metadata? table<string, any>
---@field created_at? integer

---@class terminalia.PersistedContext
---@field id string
---@field kind string
---@field label string
---@field parent_id? string
---@field metadata? table<string, any>
---@field created_at integer

---@class terminalia.TerminalContext
---@field id string
---@field kind string
---@field label string
---@field parent_id? string
---@field metadata table<string, any>
---@field created_at integer

---@class terminalia.TerminalRecord
---@field id string
---@field name string
---@field namespace string
---@field context_id string
---@field disposable boolean
---@field cwd string
---@field env? table<string, string>
---@field status terminalia.TerminalStatus
---@field command? terminalia.TerminalCommand
---@field preferred_view terminalia.ViewKind
---@field bufnr? integer
---@field job_id? integer
---@field exit_code? integer
---@field instance_id string
---@field created_at integer
---@field last_opened_at? integer

local config = require('terminalia.config')

local M = {}

local VALID_ID_PATTERN = '^[%w:_%-]+$'
local next_instance_id = 1

---@return string
local function alloc_instance_id()
    local id = string.format('terminal-instance:%d:%s:%d', vim.fn.getpid(), tostring(vim.uv.hrtime()), next_instance_id)
    next_instance_id = next_instance_id + 1
    return id
end

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

---@param value any
---@return terminalia.TerminalStatus
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
---@param opts terminalia.CreateOptions
---@return terminalia.TerminalRecord
function M.new_terminal(opts)
    M.assert_valid_id(opts.id)

    local cwd = opts.cwd or vim.fn.getcwd()
    local defaults = config.get()
    local preferred_view = opts.view or defaults.default_view

    return {
        id = opts.id,
        name = opts.name or opts.id,
        namespace = opts.namespace or defaults.default_namespace,
        context_id = opts.context_id or 'context:host',
        disposable = opts.disposable == true,
        cwd = cwd,
        env = M.normalize_env(opts.env),
        status = normalize_status(opts.status),
        command = opts.command,
        preferred_view = preferred_view,
        instance_id = type(opts.instance_id) == 'string' and opts.instance_id ~= '' and opts.instance_id
            or alloc_instance_id(),
        created_at = opts.created_at or os.time(),
        last_opened_at = opts.last_opened_at,
        exit_code = opts.exit_code,
    }
end

---Restore a terminal record from persisted metadata.
---@param opts terminalia.CreateOptions
---@return terminalia.TerminalRecord
function M.restore_terminal(opts)
    local terminal = M.new_terminal(opts)

    terminal.preferred_view = config.normalize_view(opts.view)

    if terminal.status == 'running' then
        terminal.status = 'registered'
        terminal.exit_code = nil
    end

    return terminal
end

---Convert a terminal record into a persisted metadata table.
---@param terminal terminalia.TerminalRecord
---@return terminalia.PersistedTerminal
function M.to_persisted_record(terminal)
    return {
        id = terminal.id,
        name = terminal.name,
        namespace = terminal.namespace,
        context_id = terminal.context_id,
        disposable = terminal.disposable,
        cwd = terminal.cwd,
        env = M.normalize_env(terminal.env),
        status = terminal.status,
        command = terminal.command,
        view = terminal.preferred_view,
        instance_id = terminal.instance_id,
        created_at = terminal.created_at,
        last_opened_at = terminal.last_opened_at,
        exit_code = terminal.exit_code,
    }
end

return M

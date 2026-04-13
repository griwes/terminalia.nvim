local M = {}

local HOST_CONTEXT_ID = 'context:host'
local VALID_ID_PATTERN = '^[%w:_%-]+$'

local state = {
    next_id = 1,
    current_context_id = HOST_CONTEXT_ID,
    contexts = {},
}

---@return terminal_manager.TerminalContext
local function default_host_context()
    return {
        id = HOST_CONTEXT_ID,
        kind = 'host',
        label = 'Host',
        metadata = {},
        created_at = 0,
    }
end

---@return terminal_manager.TerminalContext
local function ensure_host_context()
    local context = state.contexts[HOST_CONTEXT_ID]

    if context == nil then
        context = default_host_context()
        state.contexts[HOST_CONTEXT_ID] = context
    end

    if state.current_context_id == nil then
        state.current_context_id = HOST_CONTEXT_ID
    end

    return context
end

---@param id any
---@return boolean
local function is_valid_id(id)
    return type(id) == 'string' and id:match(VALID_ID_PATTERN) ~= nil
end

---@return string
local function alloc_id()
    local id = string.format('context:%d', state.next_id)
    state.next_id = state.next_id + 1
    return id
end

---@param metadata any
---@return table<string, any>?
local function normalize_metadata(metadata)
    if type(metadata) ~= 'table' then
        return nil
    end

    return vim.deepcopy(metadata)
end

---@param left terminal_manager.TerminalContext
---@param right terminal_manager.TerminalContext
---@return boolean
local function sort_by_id(left, right)
    if left.id == HOST_CONTEXT_ID then
        return true
    end

    if right.id == HOST_CONTEXT_ID then
        return false
    end

    return left.id < right.id
end

---@param context terminal_manager.PersistedContext
---@return terminal_manager.TerminalContext
local function restore_context(context)
    return {
        id = context.id,
        kind = context.kind or 'custom',
        label = context.label or context.id,
        parent_id = context.parent_id,
        metadata = normalize_metadata(context.metadata) or {},
        created_at = tonumber(context.created_at) or os.time(),
    }
end

---Create a new terminal context.
---@param opts terminal_manager.ContextCreateOptions
---@return terminal_manager.TerminalContext
function M.create(opts)
    opts = opts or {}

    local id = opts.id or alloc_id()

    if not is_valid_id(id) then
        error(string.format('Invalid terminal context id: %s', vim.inspect(id)))
    end

    if state.contexts[id] ~= nil then
        error(string.format('Terminal context already exists: %s', id))
    end

    if opts.parent_id ~= nil and state.contexts[opts.parent_id] == nil then
        error(string.format('Unknown terminal context id: %s', opts.parent_id))
    end

    local context = {
        id = id,
        kind = opts.kind or 'custom',
        label = opts.label or id,
        parent_id = opts.parent_id,
        metadata = normalize_metadata(opts.metadata) or {},
        created_at = opts.created_at or os.time(),
    }

    state.contexts[context.id] = context
    return context
end

---Create a child terminal context.
---@param parent_id string
---@param opts? terminal_manager.ContextCreateOptions
---@return terminal_manager.TerminalContext
function M.create_child(parent_id, opts)
    opts = opts or {}
    return M.create(vim.tbl_extend('force', opts, {
        parent_id = parent_id,
    }))
end

---Return a terminal context by id.
---@param id string
---@return terminal_manager.TerminalContext?
function M.get(id)
    ensure_host_context()
    return state.contexts[id]
end

---Return all known terminal contexts.
---@return terminal_manager.TerminalContext[]
function M.list()
    ensure_host_context()

    ---@type terminal_manager.TerminalContext[]
    local items = vim.tbl_values(state.contexts)
    table.sort(items, sort_by_id)
    return vim.tbl_map(vim.deepcopy, items)
end

---Return the current terminal context.
---@return terminal_manager.TerminalContext
function M.current()
    ensure_host_context()
    return vim.deepcopy(assert(state.contexts[state.current_context_id]))
end

---Set the current terminal context.
---@param id string
---@return terminal_manager.TerminalContext
function M.set_current(id)
    ensure_host_context()

    if state.contexts[id] == nil then
        error(string.format('Unknown terminal context id: %s', id))
    end

    state.current_context_id = id
    return M.current()
end

---Reset the current terminal context back to the host context.
---@return terminal_manager.TerminalContext
function M.clear_current()
    ensure_host_context()
    state.current_context_id = HOST_CONTEXT_ID
    return M.current()
end

---Return the host/root terminal context.
---@return terminal_manager.TerminalContext
function M.host()
    return vim.deepcopy(ensure_host_context())
end

---@return integer
local function compute_next_id()
    local next_id = 1

    for id in pairs(state.contexts) do
        local numeric = tonumber(id:match('^context:(%d+)$'))

        if numeric ~= nil and numeric >= next_id then
            next_id = numeric + 1
        end
    end

    return next_id
end

---Return a persistence snapshot for context state.
---@return { next_context_id: integer, current_context_id: string, contexts: terminal_manager.PersistedContext[] }
function M.snapshot()
    ensure_host_context()

    local contexts = {}

    for _, context in ipairs(M.list()) do
        table.insert(contexts, {
            id = context.id,
            kind = context.kind,
            label = context.label,
            parent_id = context.parent_id,
            metadata = normalize_metadata(context.metadata) or {},
            created_at = context.created_at,
        })
    end

    return {
        next_context_id = state.next_id,
        current_context_id = state.current_context_id,
        contexts = contexts,
    }
end

---Restore context state from a persistence payload.
---@param payload? { next_context_id?: integer, current_context_id?: string, contexts?: terminal_manager.PersistedContext[] }
function M.restore_payload(payload)
    state.next_id = 1
    state.current_context_id = HOST_CONTEXT_ID
    state.contexts = {}

    local items = payload and payload.contexts or {}

    if type(items) == 'table' then
        for _, item in ipairs(items) do
            if type(item) == 'table' and is_valid_id(item.id) then
                state.contexts[item.id] = restore_context(item)
            end
        end
    end

    ensure_host_context()

    if
        payload ~= nil
        and type(payload.current_context_id) == 'string'
        and state.contexts[payload.current_context_id] ~= nil
    then
        state.current_context_id = payload.current_context_id
    end

    state.next_id = math.max(tonumber(payload and payload.next_context_id) or 1, compute_next_id())
end

---Clear in-memory context state back to the host context only.
function M.clear()
    state.next_id = 1
    state.current_context_id = HOST_CONTEXT_ID
    state.contexts = {}
    ensure_host_context()
end

return M

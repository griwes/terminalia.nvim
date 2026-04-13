local config = require('terminal_manager.config')
local contexts = require('terminal_manager.contexts')
local history = require('terminal_manager.history')
local model = require('terminal_manager.model')
local persistence = require('terminal_manager.persistence')

local M = {}

local state = {
    next_id = 1,
    terminals = {},
}

---@return boolean
local function persistence_enabled()
    return require('terminal_manager.config').get().persist_terminals
end

local function teardown_state(opts)
    local current_buf = vim.api.nvim_get_current_buf()

    if vim.api.nvim_buf_is_valid(current_buf) then
        vim.cmd('enew')
    end

    for _, terminal in pairs(state.terminals) do
        if terminal.bufnr and vim.api.nvim_buf_is_valid(terminal.bufnr) then
            pcall(vim.api.nvim_buf_delete, terminal.bufnr, { force = true })
        end
    end

    state.next_id = 1
    state.terminals = {}
    contexts.clear()

    if opts == nil or opts.wipe_storage ~= false then
        history.clear_all()
    end

    if (opts == nil or opts.wipe_storage ~= false) and persistence_enabled() then
        persistence.clear()
    end
end

---@param bufnr? integer
---@return boolean
local function can_delete_buffer(bufnr)
    return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) and bufnr ~= vim.api.nvim_get_current_buf()
end

---@return string
local function alloc_id()
    local id = string.format('terminal:%d', state.next_id)
    state.next_id = state.next_id + 1
    return id
end

---@return terminal_manager.TerminalRecord[]
local function sorted_terminals()
    ---@type terminal_manager.TerminalRecord[]
    local items = vim.tbl_values(state.terminals)

    table.sort(items, function(left, right)
        return left.id < right.id
    end)

    return items
end

---@param id any
---@return integer?
local function parse_terminal_index(id)
    if type(id) ~= 'string' then
        return nil
    end

    local suffix = id:match('^terminal:(%d+)$')
    if suffix == nil then
        return nil
    end

    return tonumber(suffix)
end

local function persist()
    if not persistence_enabled() then
        return
    end

    local persisted_terminals = vim.tbl_filter(function(terminal)
        return terminal.disposable == false
    end, sorted_terminals())

    local context_snapshot = contexts.snapshot()

    persistence.save({
        next_id = state.next_id,
        next_context_id = context_snapshot.next_context_id,
        current_context_id = context_snapshot.current_context_id,
        contexts = context_snapshot.contexts,
        terminals = persisted_terminals,
    })
end

---Create a new terminal record and register it.
---@param opts? Partial<terminal_manager.CreateOptions>
---@return terminal_manager.TerminalRecord
function M.create(opts)
    opts = opts or {}

    if opts.view ~= nil and config.normalize_view(opts.view) ~= opts.view then
        error(string.format('Unsupported terminal view: %s', opts.view))
    end

    local id = opts.id or alloc_id()
    model.assert_valid_id(id)

    local terminal = model.new_terminal(vim.tbl_extend('force', opts, {
        id = id,
        context_id = opts.context_id or contexts.current().id,
    }))

    state.terminals[terminal.id] = terminal
    persist()
    return terminal
end

---Look up a terminal by id.
---@param id string
---@return terminal_manager.TerminalRecord?
function M.get(id)
    return state.terminals[id]
end

---Return all known terminals sorted by id.
---@param filters? terminal_manager.ListFilters
---@return terminal_manager.TerminalRecord[]
function M.list(filters)
    local items = sorted_terminals()

    if not filters then
        return items
    end

    return vim.tbl_filter(function(item)
        if filters.namespace and item.namespace ~= filters.namespace then
            return false
        end

        if filters.cwd_prefix and not vim.startswith(item.cwd, filters.cwd_prefix) then
            return false
        end

        if filters.context_id and item.context_id ~= filters.context_id then
            return false
        end

        return true
    end, items)
end

---Update a terminal record in place.
---@param id string
---@param patch table<string, any>
---@return terminal_manager.TerminalRecord
function M.update(id, patch)
    local terminal = assert(state.terminals[id], string.format('Unknown terminal id: %s', id))

    for key, value in pairs(patch) do
        if value == vim.NIL then
            terminal[key] = nil
        elseif key == 'env' then
            terminal[key] = model.normalize_env(value)
        else
            terminal[key] = value
        end
    end

    persist()
    return terminal
end

---Remove a terminal from the registry.
---@param id string
---@param opts? { wipe_buffer?: boolean, clear_history?: boolean }
---@return terminal_manager.TerminalRecord?
function M.remove(id, opts)
    local terminal = state.terminals[id]

    if not terminal then
        return nil
    end

    local wipe_buffer = opts == nil or opts.wipe_buffer ~= false
    local clear_history = opts == nil or opts.clear_history ~= false

    if wipe_buffer and can_delete_buffer(terminal.bufnr) then
        pcall(vim.api.nvim_buf_delete, terminal.bufnr, { force = true })
    end

    state.terminals[id] = nil
    if clear_history then
        history.clear(id)
    end
    persist()

    return terminal
end

---@param terminal terminal_manager.TerminalRecord
---@return terminal_manager.TerminalRecord
local function restore_with_fresh_id(terminal)
    local restored = vim.deepcopy(terminal)
    restored.id = alloc_id()
    state.terminals[restored.id] = restored
    return restored
end

---Restore persisted terminal metadata into the registry.
---When `merge` is true, existing in-memory terminals are preserved and restored
---records that collide on id are assigned fresh ids instead of being dropped.
---@param opts? { force?: boolean, merge?: boolean }
function M.restore(opts)
    local merge = opts ~= nil and opts.merge == true

    if opts == nil or opts.force ~= true then
        if next(state.terminals) ~= nil then
            return
        end
    end

    if not persistence_enabled() then
        return
    end

    if not merge then
        teardown_state({ wipe_storage = false })
    end

    local payload = persistence.load()
    local collided = {}
    local next_id = merge and state.next_id or 1
    contexts.restore_payload(payload)

    for _, terminal in ipairs(payload.terminals) do
        local terminal_id = parse_terminal_index(terminal.id)

        if state.terminals[terminal.id] == nil then
            state.terminals[terminal.id] = terminal
        elseif merge then
            table.insert(collided, terminal)
        end

        if terminal_id ~= nil and terminal_id >= next_id then
            next_id = terminal_id + 1
        end
    end

    for _, terminal in ipairs(collided) do
        local restored = restore_with_fresh_id(terminal)
        local restored_id = parse_terminal_index(restored.id)
        if restored_id ~= nil and restored_id >= next_id then
            next_id = restored_id + 1
        end
    end

    state.next_id = math.max(payload.next_id or 1, next_id)
end

---Clear registry state and wipe any created terminal buffers.
---@param opts? { wipe_storage?: boolean }
function M.clear(opts)
    teardown_state(opts)
end

return M

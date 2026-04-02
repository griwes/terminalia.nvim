local history = require('terminal_manager.history')
local model = require('terminal_manager.model')
local persistence = require('terminal_manager.persistence')

local M = {}

local state = {
    next_id = 1,
    terminals = {},
}

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

---@return boolean
local function persistence_enabled()
    return require('terminal_manager.config').get().persist_terminals
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

    persistence.save({
        next_id = state.next_id,
        terminals = persisted_terminals,
    })
end

---Create a new terminal record and register it.
---@param opts? Partial<terminal_manager.CreateOptions>
---@return terminal_manager.TerminalRecord
function M.create(opts)
    local terminal = model.new_terminal(vim.tbl_extend('force', opts or {}, {
        id = alloc_id(),
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
        else
            terminal[key] = value
        end
    end

    persist()
    return terminal
end

---Remove a terminal from the registry.
---@param id string
---@return terminal_manager.TerminalRecord?
function M.remove(id)
    local terminal = state.terminals[id]

    if not terminal then
        return nil
    end

    if terminal.bufnr and vim.api.nvim_buf_is_valid(terminal.bufnr) then
        pcall(vim.api.nvim_buf_delete, terminal.bufnr, { force = true })
    end

    state.terminals[id] = nil
    history.clear(id)
    persist()

    return terminal
end

---Restore persisted terminal metadata into the registry.
---@param opts? { force?: boolean }
function M.restore(opts)
    if opts == nil or opts.force ~= true then
        if next(state.terminals) ~= nil then
            return
        end
    end

    state.next_id = 1
    state.terminals = {}

    if not persistence_enabled() then
        return
    end

    local payload = persistence.load()
    local next_id = 1

    for _, terminal in ipairs(payload.terminals) do
        local terminal_id = parse_terminal_index(terminal.id)
        if terminal_id ~= nil then
            state.terminals[terminal.id] = terminal
            if terminal_id >= next_id then
                next_id = terminal_id + 1
            end
        end
    end

    state.next_id = next_id
end

---Clear registry state and wipe any created terminal buffers.
---@param opts? { wipe_storage?: boolean }
function M.clear(opts)
    for _, terminal in pairs(state.terminals) do
        if terminal.bufnr and vim.api.nvim_buf_is_valid(terminal.bufnr) then
            pcall(vim.api.nvim_buf_delete, terminal.bufnr, { force = true })
        end
    end

    state.next_id = 1
    state.terminals = {}

    if opts == nil or opts.wipe_storage ~= false then
        history.clear_all()
    end

    if (opts == nil or opts.wipe_storage ~= false) and persistence_enabled() then
        persistence.clear()
    end
end

return M

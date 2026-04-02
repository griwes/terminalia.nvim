local model = require('terminal_manager.model')

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

---Create a new terminal record and register it.
---@param opts? Partial<terminal_manager.CreateOptions>
---@return terminal_manager.TerminalRecord
function M.create(opts)
    local terminal = model.new_terminal(vim.tbl_extend('force', opts or {}, {
        id = alloc_id(),
    }))

    state.terminals[terminal.id] = terminal
    return terminal
end

---Look up a terminal by id.
---@param id string
---@return terminal_manager.TerminalRecord?
function M.get(id)
    return state.terminals[id]
end

---Return all known terminals sorted by id.
---@return terminal_manager.TerminalRecord[]
function M.list()
    ---@type terminal_manager.TerminalRecord[]
    local items = vim.tbl_values(state.terminals)

    table.sort(items, function(left, right)
        return left.id < right.id
    end)

    return items
end

---Update a terminal record in place.
---@param id string
---@param patch table<string, any>
---@return terminal_manager.TerminalRecord
function M.update(id, patch)
    local terminal = assert(state.terminals[id], string.format('Unknown terminal id: %s', id))

    for key, value in pairs(patch) do
        terminal[key] = value
    end

    return terminal
end

---Clear registry state and wipe any created terminal buffers.
function M.clear()
    for _, terminal in pairs(state.terminals) do
        if terminal.bufnr and vim.api.nvim_buf_is_valid(terminal.bufnr) then
            pcall(vim.api.nvim_buf_delete, terminal.bufnr, { force = true })
        end
    end

    state.next_id = 1
    state.terminals = {}
end

return M

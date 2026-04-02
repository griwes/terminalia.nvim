local config = require('terminal_manager.config')
local registry = require('terminal_manager.registry')
local runtime = require('terminal_manager.runtime.native')
local split_view = require('terminal_manager.view.split')
local float_view = require('terminal_manager.view.float')

local M = {}
local openers = {
    split = split_view.open,
    float = float_view.open,
}

---@param terminal terminal_manager.TerminalRecord
---@param opts? { view?: terminal_manager.ViewKind }
---@return terminal_manager.ViewKind
local function resolve_view(terminal, opts)
    local view = opts and opts.view or terminal.preferred_view or config.get().default_view

    if openers[view] == nil then
        error(string.format('Unsupported terminal view: %s', view))
    end

    return view
end

---@param terminal terminal_manager.TerminalRecord
---@param view terminal_manager.ViewKind
local function reveal(terminal, view)
    return openers[view](terminal, config.get())
end

---Create a terminal record without opening it.
---@param opts? Partial<terminal_manager.CreateOptions>
---@return terminal_manager.TerminalRecord
function M.create(opts)
    return registry.create(opts)
end

---Create and immediately reveal a terminal.
---@param opts? Partial<terminal_manager.CreateOptions>
---@return terminal_manager.TerminalRecord
function M.create_and_open(opts)
    local terminal = M.create(opts)
    return M.open(terminal.id, {
        view = opts and opts.view or nil,
    })
end

---Look up a terminal by id.
---@param id string
---@return terminal_manager.TerminalRecord?
function M.get(id)
    return registry.get(id)
end

---Reveal an existing terminal and start the runtime if necessary.
---@param id string
---@param opts? { view?: terminal_manager.ViewKind }
---@return terminal_manager.TerminalRecord
function M.open(id, opts)
    local terminal = assert(registry.get(id), string.format('Unknown terminal id: %s', id))
    local view = resolve_view(terminal, opts)

    runtime.ensure_started(terminal)
    reveal(terminal, view)

    return registry.update(id, {
        last_opened_at = os.time(),
        preferred_view = view,
    })
end

---Return all known terminals.
---@return terminal_manager.TerminalRecord[]
function M.list()
    return registry.list()
end

---Format terminals for command-line display.
---@return string[]
function M.list_lines()
    local lines = {}

    for _, terminal in ipairs(M.list()) do
        table.insert(
            lines,
            string.format('%s  [%s]  %s  %s', terminal.id, terminal.namespace, terminal.status, terminal.name)
        )
    end

    return lines
end

---Reset all in-memory state.
function M.clear()
    registry.clear()
end

return M

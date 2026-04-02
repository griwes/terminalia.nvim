local config = require('terminal_manager.config')
local history = require('terminal_manager.history')
local registry = require('terminal_manager.registry')
local runtime = require('terminal_manager.runtime.native')
local history_view = require('terminal_manager.view.history')
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
        view = opts and opts.view,
    })
end

---Start a terminal without revealing a window.
---@param id string
---@return terminal_manager.TerminalRecord
function M.start(id)
    local terminal = assert(registry.get(id), string.format('Unknown terminal id: %s', id))
    return runtime.ensure_started(terminal)
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
---@param filters? terminal_manager.ListFilters
---@return terminal_manager.TerminalRecord[]
function M.list(filters)
    return registry.list(filters)
end

---Update the tracked cwd metadata for a terminal.
---@param id string
---@param cwd string
---@return terminal_manager.TerminalRecord
function M.set_cwd(id, cwd)
    return registry.update(id, {
        cwd = cwd,
    })
end

---Send stdin to a started terminal job.
---@param id string
---@param data string
---@return terminal_manager.TerminalRecord
function M.send(id, data)
    local terminal = assert(registry.get(id), string.format('Unknown terminal id: %s', id))
    return runtime.send(terminal, data)
end

---Return the captured history lines for a terminal id.
---@param id string
---@return string[]
function M.history_lines(id)
    return history.read_lines(id)
end

---Return the captured output snapshot for a terminal id.
---@param id string
---@return terminal_manager.TerminalOutput
function M.output(id)
    local terminal = assert(registry.get(id), string.format('Unknown terminal id: %s', id))
    local output, has_live_output = runtime.output(id)

    if not has_live_output then
        output = history.read_text(id)
    end

    return {
        output = output,
        status = terminal.status,
        exit_code = terminal.exit_code,
    }
end

---Wait for a terminal job to exit.
---@param id string
---@param timeout_ms? integer
---@return terminal_manager.TerminalRecord?
function M.wait(id, timeout_ms)
    local terminal = assert(registry.get(id), string.format('Unknown terminal id: %s', id))
    return runtime.wait_for_exit(terminal, timeout_ms)
end

---Request termination of a terminal job.
---@param id string
---@return terminal_manager.TerminalRecord
function M.kill(id)
    local terminal = assert(registry.get(id), string.format('Unknown terminal id: %s', id))
    return runtime.kill(terminal)
end

---Open a scratch history view for a terminal id.
---@param id string
---@return integer
function M.open_history(id)
    local terminal = assert(registry.get(id), string.format('Unknown terminal id: %s', id))
    local lines = history.read_lines(id)

    return history_view.open(terminal, lines, config.get())
end

---Format terminals for command-line display.
---@param filters? terminal_manager.ListFilters
---@return string[]
function M.list_lines(filters)
    local lines = {}

    for _, terminal in ipairs(M.list(filters)) do
        table.insert(
            lines,
            string.format(
                '%s  [%s]  %s  %s  %s',
                terminal.id,
                terminal.namespace,
                terminal.status,
                terminal.cwd,
                terminal.name
            )
        )
    end

    return lines
end

---Remove a terminal from the registry.
---@param id string
---@return terminal_manager.TerminalRecord?
function M.delete(id)
    if registry.get(id) == nil then
        return nil
    end

    return M.release(id)
end

---Stop a terminal if needed and remove it from the registry.
---@param id string
---@return terminal_manager.TerminalRecord?
function M.release(id)
    local terminal = assert(registry.get(id), string.format('Unknown terminal id: %s', id))

    if terminal.status == 'running' then
        runtime.kill(terminal)
        runtime.wait_for_exit(terminal, 1000)
    end

    runtime.clear_output(id)
    return registry.remove(id)
end

---Restore any persisted terminal metadata into the registry.
---@param opts? { force?: boolean }
function M.restore(opts)
    registry.restore(opts)
end

---Reset all in-memory state.
---@param opts? { wipe_storage?: boolean }
function M.clear(opts)
    runtime.clear()
    registry.clear(opts)
end

return M

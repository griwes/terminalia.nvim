---@alias terminal_manager.TerminalStatus 'registered'|'running'|'exited'
---@alias terminal_manager.TerminalCommand string|string[]

---@class terminal_manager.CreateOptions
---@field id string
---@field name? string
---@field namespace? string
---@field disposable? boolean
---@field cwd? string
---@field status? terminal_manager.TerminalStatus
---@field command? terminal_manager.TerminalCommand
---@field view? terminal_manager.ViewKind

---@class terminal_manager.TerminalRecord
---@field id string
---@field name string
---@field namespace string
---@field disposable boolean
---@field cwd string
---@field status terminal_manager.TerminalStatus
---@field command? terminal_manager.TerminalCommand
---@field preferred_view terminal_manager.ViewKind
---@field bufnr? integer
---@field job_id? integer
---@field exit_code? integer
---@field created_at integer
---@field last_opened_at? integer

local M = {}

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
        status = opts.status or 'registered',
        command = opts.command,
        preferred_view = preferred_view,
        created_at = os.time(),
    }
end

return M

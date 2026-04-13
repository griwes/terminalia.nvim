local M = {}

local providers = {}

---@param command string|string[]
---@return string[]
local function normalize_command(command)
    if type(command) == 'table' then
        return vim.deepcopy(command)
    end

    return { 'sh', '-lc', command }
end

---@param command string|string[]
---@return string
local function display_command(command)
    if type(command) == 'table' then
        return table.concat(command, ' ')
    end

    return command
end

local function register_host_provider()
    providers.host = {
        plan_command = function(context, command, opts)
            local cfg = require('terminal_manager.config').get()

            return {
                context = context,
                cmd = normalize_command(command),
                cwd = opts and opts.cwd or vim.fn.getcwd(),
                env = opts and opts.env and vim.deepcopy(opts.env) or nil,
                default_name = string.format('%s %s', context.label, display_command(command)),
                terminal_name = opts and opts.terminal_name or display_command(command),
                terminal_namespace = opts and opts.terminal_namespace or cfg.overseer_terminal_namespace,
                metadata = {},
            }
        end,
    }
end

function M.reset()
    providers = {}
    register_host_provider()
end

---@param kind string
---@param provider { plan_command: fun(context: terminal_manager.TerminalContext, command: string|string[], opts?: table): table }
function M.register(kind, provider)
    assert(type(kind) == 'string' and kind ~= '', 'Context provider kind must be a non-empty string')
    assert(
        type(provider) == 'table' and type(provider.plan_command) == 'function',
        'Context provider must define plan_command'
    )
    providers[kind] = provider
end

---@param kind string
---@return table?
function M.get(kind)
    return providers[kind]
end

---@param context terminal_manager.TerminalContext
---@param command string|string[]
---@param opts? table
---@return table
function M.plan_command(context, command, opts)
    local provider = assert(
        providers[context.kind],
        string.format('No terminal context provider registered for kind: %s', context.kind)
    )
    return provider.plan_command(context, command, opts)
end

M.reset()

return M

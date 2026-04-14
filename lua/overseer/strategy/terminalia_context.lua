local overseer_helper = require('terminalia.overseer')

local M = {}

---@class terminalia.OverseerStrategyOptions
---@field context_id? string
---@field context_id_resolver? fun(task: overseer.Task): string?
---@field preserve_output? boolean
---@field use_terminal? boolean
---@field wrap_opts? table<string, any>
---@field cwd? string
---@field command_cwd? string
---@field remote_env? table<string, string>
---@field remote_env_resolver? fun(task: overseer.Task): table<string, string>?
---@field terminal_name? string
---@field terminal_namespace? string
---@field view? string
---@field metadata? table<string, any>

---@class terminalia.OverseerStrategy
---@field delegate overseer.Strategy
---@field opts terminalia.OverseerStrategyOptions
local Strategy = {}

---@return table
local function load_jobstart_strategy()
    return require('overseer.strategy.jobstart')
end

---@param task overseer.Task
---@param opts terminalia.OverseerStrategyOptions
---@return table<string, any>
local function build_task_definition(task, opts)
    local context_id = opts.context_id_resolver and opts.context_id_resolver(task) or opts.context_id

    return overseer_helper.build_task_definition(task.cmd, {
        context_id = context_id,
        cwd = opts.cwd or task.cwd,
        env = opts.env and vim.deepcopy(opts.env) or nil,
        name = task.name,
        metadata = vim.tbl_deep_extend('force', vim.deepcopy(task.metadata or {}), vim.deepcopy(opts.metadata or {})),
        command_cwd = opts.command_cwd or task.cwd,
        remote_env = opts.remote_env_resolver and opts.remote_env_resolver(task)
            or (opts.remote_env and vim.deepcopy(opts.remote_env) or nil),
        terminal_name = opts.terminal_name or task.name,
        terminal_namespace = opts.terminal_namespace or 'overseer',
        view = opts.view,
    })
end

---@param task overseer.Task
---@param definition table<string, any>
---@return table
local function proxy_task(task, definition)
    local proxy = {
        cmd = vim.deepcopy(definition.cmd),
        cwd = definition.cwd,
        env = definition.env,
        name = task.name,
    }

    function proxy:dispatch(name, ...)
        return task:dispatch(name, ...)
    end

    function proxy:on_exit(code)
        return task:on_exit(code)
    end

    return proxy
end

---@param opts? terminalia.OverseerStrategyOptions
---@return overseer.Strategy
function M.new(opts)
    local normalized = vim.deepcopy(opts or {})
    local delegate = load_jobstart_strategy().new({
        preserve_output = normalized.preserve_output,
        use_terminal = normalized.use_terminal,
        wrap_opts = normalized.wrap_opts and vim.deepcopy(normalized.wrap_opts) or nil,
    })
    local strategy = {
        delegate = delegate,
        opts = normalized,
    }

    return setmetatable(strategy, { __index = Strategy })
end

function Strategy:reset()
    self.delegate:reset()
end

---@return integer?
function Strategy:get_bufnr()
    return self.delegate:get_bufnr()
end

---@param task overseer.Task
function Strategy:start(task)
    local definition = build_task_definition(task, self.opts)

    task.metadata = definition.metadata
    self.delegate:start(proxy_task(task, definition))
end

function Strategy:stop()
    self.delegate:stop()
end

function Strategy:dispose()
    self.delegate:dispose()
end

return M

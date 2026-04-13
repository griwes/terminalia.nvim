local config = require('terminal_manager.config')
local contexts = require('terminal_manager.contexts')
local context_providers = require('terminal_manager.context_providers')

local M = {}

---@return table
local function load_overseer()
    local ok, overseer = pcall(require, 'overseer')

    if ok and overseer ~= nil then
        return overseer
    end

    error('overseer.nvim is unavailable')
end

---@param command string|string[]
---@return string
local function display_command(command)
    if type(command) == 'table' then
        return table.concat(command, ' ')
    end

    return command
end

---@param context_id? string
---@return terminal_manager.TerminalContext
function M.resolve_context(context_id)
    if type(context_id) == 'string' and context_id ~= '' then
        return assert(contexts.get(context_id), string.format('Unknown terminal context id: %s', context_id))
    end

    local configured = config.get().overseer_context_id

    if type(configured) == 'string' and configured ~= '' then
        return assert(contexts.get(configured), string.format('Unknown terminal context id: %s', configured))
    end

    return contexts.current()
end

---@param context terminal_manager.TerminalContext
---@param command string|string[]
---@param opts? table
---@return table
local function build_plan(context, command, opts)
    local plan = context_providers.plan_command(context, command, opts)

    plan.context = context
    return plan
end

---@param metadata table<string, any>?
---@param plan table
---@return table<string, any>
local function build_metadata(metadata, plan)
    local merged = plan.metadata and vim.deepcopy(plan.metadata) or {}

    merged.terminal_manager = vim.tbl_deep_extend('force', merged.terminal_manager or {}, {
        context_id = plan.context.id,
        context_kind = plan.context.kind,
        context_label = plan.context.label,
        cmd = vim.deepcopy(plan.cmd),
        cwd = plan.cwd,
        terminal_name = plan.terminal_name,
        terminal_namespace = plan.terminal_namespace,
    })

    if metadata ~= nil then
        merged = vim.tbl_deep_extend('force', merged, vim.deepcopy(metadata))
    end

    return merged
end

---@param command string|string[]
---@param opts? { context_id?: string, cwd?: string, env?: table<string,string>, name?: string, metadata?: table<string, any>, components?: any[], strategy?: any, default_component_params?: table<string, any>, terminal_name?: string, terminal_namespace?: string }
---@return table<string, any>
function M.build_task_definition(command, opts)
    local context = M.resolve_context(opts and opts.context_id or nil)
    local plan = build_plan(context, command, opts)
    local definition = {
        cmd = vim.deepcopy(plan.cmd),
        cwd = plan.cwd,
        name = opts and opts.name
            or plan.default_name
            or string.format('%s %s', context.label, display_command(command)),
        metadata = build_metadata(opts and opts.metadata or nil, plan),
    }

    if opts and opts.env ~= nil then
        definition.env = vim.deepcopy(opts.env)
    end

    if opts and opts.components ~= nil then
        definition.components = vim.deepcopy(opts.components)
    end

    if opts and opts.strategy ~= nil then
        definition.strategy = vim.deepcopy(opts.strategy)
    end

    if opts and opts.default_component_params ~= nil then
        definition.default_component_params = vim.deepcopy(opts.default_component_params)
    end

    return definition
end

---@param command string|string[]
---@param opts? table
---@return overseer.Task
function M.new_task(command, opts)
    return load_overseer().new_task(M.build_task_definition(command, opts))
end

---@param command string|string[]
---@param opts? table
---@return overseer.Task
function M.run_task(command, opts)
    local task = M.new_task(command, opts)
    task:start()
    return task
end

---@param template { name: string, desc?: string, tags?: string[], params?: table<string, any>, condition?: table<string, any>, command?: string|string[], opts?: table, build?: fun(params: table): { command: string|string[], opts?: table } }
function M.register_template(template)
    load_overseer().register_template({
        name = template.name,
        desc = template.desc,
        tags = template.tags and vim.deepcopy(template.tags) or nil,
        params = template.params and vim.deepcopy(template.params) or nil,
        condition = template.condition and vim.deepcopy(template.condition) or nil,
        builder = function(params)
            local build

            if template.build ~= nil then
                build = template.build(params)
                if build == nil or build.command == nil then
                    error(string.format('TerminalManager Overseer template %s returned no command', template.name))
                end
            else
                if template.command == nil then
                    error(
                        string.format('TerminalManager Overseer template %s requires command or build', template.name)
                    )
                end
                build = {
                    command = template.command,
                    opts = template.opts and vim.deepcopy(template.opts) or nil,
                }
            end

            return M.build_task_definition(build.command, build.opts)
        end,
    })
end

return M

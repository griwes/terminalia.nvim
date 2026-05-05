local config = require('terminalia.config')
local relay_open = require('terminalia.relay.open')

local M = {}

---@class terminalia.GitToolPayload
---@field kind? 'difftool'|'mergetool'
---@field local? string
---@field remote? string
---@field base? string
---@field merged? string

---@class terminalia.GitToolOpenOptions
---@field stdin_data? string|string[]
---@field on_complete? fun(status: 'ok'|'error')

---@param value any
---@return boolean
local function non_empty_string(value)
    return type(value) == 'string' and value ~= ''
end

---@param value string
---@return boolean
local function absolute_path(value)
    return value:sub(1, 1) == '/' or value:match('^%a:[/\\]') ~= nil
end

---@param cwd string
---@param value any
---@return string?
local function resolve_path(cwd, value)
    if not non_empty_string(value) then
        return nil
    end

    if absolute_path(value) then
        return vim.fs.normalize(value)
    end

    return vim.fs.normalize(vim.fs.joinpath(cwd, value))
end

---@param path string
---@return terminalia.ExternalOpenTarget
local function target_for(path)
    return {
        raw = path,
        path = path,
        is_directory = vim.fn.isdirectory(path) == 1,
    }
end

---@param plan terminalia.ExternalOpenPlan
---@param targets terminalia.ExternalOpenTarget[]
---@param diff? boolean
---@return terminalia.ExternalOpenPlan
local function sanitized_plan(plan, targets, diff)
    return {
        cwd = plan.cwd,
        open_policy = plan.open_policy,
        targets = targets,
        pre_commands = {},
        commands = {},
        passthrough_args = {},
        diff = diff == true,
    }
end

---@return boolean
local function codediff_available()
    return vim.fn.exists(':CodeDiff') == 2
end

---@return boolean
local function should_use_codediff()
    local backend = config.get().external_git_tool_backend

    if backend == 'native' then
        return false
    end

    return codediff_available()
end

---@param args string[]
local function run_codediff(args)
    local escaped = {}

    for _, arg in ipairs(args) do
        table.insert(escaped, vim.fn.fnameescape(arg))
    end

    vim.cmd('CodeDiff ' .. table.concat(escaped, ' '))
end

---@param opts terminalia.GitToolOpenOptions
---@return fun(status: 'ok'|'error')?
local function codediff_completion(opts)
    if type(opts.on_complete) ~= 'function' then
        return nil
    end

    local completed = false
    local autocmd_id
    local opened_tabpage

    local function complete(status)
        if completed then
            return
        end

        completed = true
        if autocmd_id ~= nil then
            pcall(vim.api.nvim_del_autocmd, autocmd_id)
        end
        opts.on_complete(status)
    end

    autocmd_id = vim.api.nvim_create_autocmd('User', {
        pattern = 'CodeDiffClose',
        desc = 'Complete Terminalia Git tool wait token when CodeDiff closes',
        callback = function(event)
            if opened_tabpage == nil or type(event.data) ~= 'table' or event.data.tabpage ~= opened_tabpage then
                return
            end

            complete('ok')
        end,
    })

    return function(status)
        if status == 'error' then
            complete('error')
            return
        end

        opened_tabpage = vim.api.nvim_get_current_tabpage()
    end
end

---@param args string[]
---@param opts terminalia.GitToolOpenOptions
local function run_codediff_git_tool(args, opts)
    local mark_opened = codediff_completion(opts)

    local ok, err = pcall(run_codediff, args)

    if not ok then
        if mark_opened ~= nil then
            mark_opened('error')
        end
        error(err)
    end

    if mark_opened ~= nil then
        mark_opened('ok')
    end
end

---@param command string
---@return string?
local function parse_codediff_merge_target(command)
    local target = command:match('^%s*CodeDiff%s+merge%s+(.+)%s*$')

    if target == nil then
        return nil
    end

    return target:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", '%1')
end

---@param command string
---@return string?, string?
local function parse_codediff_file_targets(command)
    local rest = command:match('^%s*CodeDiff%s+file%s+(.+)%s*$')

    if rest == nil then
        return nil, nil
    end

    local first, second = rest:match('^"([^"]+)"%s+"([^"]+)"$')

    if first ~= nil then
        return first, second
    end

    first, second = rest:match("^'([^']+)'%s+'([^']+)'$")

    if first ~= nil then
        return first, second
    end

    return rest:match('^(%S+)%s+(%S+)$')
end

---@param commands string[]
---@return string?
local function safe_merge_command_target(commands)
    if #commands ~= 1 then
        return nil
    end

    return parse_codediff_merge_target(commands[1])
end

---@param commands string[]
---@return string?, string?
local function safe_file_command_targets(commands)
    if #commands ~= 1 then
        return nil, nil
    end

    return parse_codediff_file_targets(commands[1])
end

---@param payload table
---@return terminalia.GitToolPayload?
local function git_tool_payload(payload)
    if type(payload.git_tool) ~= 'table' then
        return nil
    end

    return payload.git_tool
end

---@param plan terminalia.ExternalOpenPlan
---@param tool terminalia.GitToolPayload?
---@return string?, string?
local function difftool_targets(plan, tool)
    local left = resolve_path(plan.cwd, tool and tool['local'])
    local right = resolve_path(plan.cwd, tool and tool.remote)

    if left ~= nil and right ~= nil then
        return left, right
    end

    left, right = safe_file_command_targets(plan.commands or {})
    left = resolve_path(plan.cwd, left)
    right = resolve_path(plan.cwd, right)

    if left ~= nil and right ~= nil then
        return left, right
    end

    if #(plan.targets or {}) >= 2 then
        return plan.targets[1].path, plan.targets[2].path
    end

    return nil, nil
end

---@param plan terminalia.ExternalOpenPlan
---@param tool terminalia.GitToolPayload?
---@return string?
local function mergetool_target(plan, tool)
    local merged = resolve_path(plan.cwd, tool and tool.merged)

    if merged ~= nil then
        return merged
    end

    merged = resolve_path(plan.cwd, safe_merge_command_target(plan.commands or {}))

    if merged ~= nil then
        return merged
    end

    if #(plan.targets or {}) == 1 then
        return plan.targets[1].path
    end

    return nil
end

---@param plan terminalia.ExternalOpenPlan
---@param payload table
---@param opts? terminalia.GitToolOpenOptions
---@return boolean
function M.try_open(plan, payload, opts)
    opts = opts or {}

    if #(plan.pre_commands or {}) > 0 or #(plan.passthrough_args or {}) > 0 then
        return false
    end

    local tool = git_tool_payload(payload)
    local kind = tool and tool.kind
    local commands = plan.commands or {}
    local merge_command_target = safe_merge_command_target(commands)
    local file_command_left, file_command_right = safe_file_command_targets(commands)

    if #commands > 0 and merge_command_target == nil and file_command_left == nil then
        return false
    end

    if kind == 'mergetool' or (kind == nil and merge_command_target ~= nil) then
        local merged = mergetool_target(plan, tool)

        if merged == nil then
            return false
        end

        if should_use_codediff() then
            run_codediff_git_tool({ 'merge', merged }, opts)
        else
            relay_open.open_plan(sanitized_plan(plan, { target_for(merged) }, false), opts)
            if type(opts.on_complete) == 'function' then
                opts.on_complete('ok')
            end
        end

        return true
    end

    if kind == 'difftool' or plan.diff or file_command_left ~= nil or file_command_right ~= nil then
        local left, right = difftool_targets(plan, tool)

        if left == nil or right == nil then
            return false
        end

        if should_use_codediff() then
            run_codediff_git_tool({ 'file', left, right }, opts)
        else
            relay_open.open_plan(sanitized_plan(plan, { target_for(left), target_for(right) }, true), opts)
            if type(opts.on_complete) == 'function' then
                opts.on_complete('ok')
            end
        end

        return true
    end

    return false
end

return M

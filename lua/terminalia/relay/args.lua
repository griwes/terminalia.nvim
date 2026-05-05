local config = require('terminalia.config')

local M = {}

---@class terminalia.ExternalOpenTarget
---@field raw string
---@field path? string
---@field line? integer
---@field col? integer
---@field stdin? boolean
---@field is_directory? boolean

---@class terminalia.ExternalOpenPlan
---@field cwd string
---@field open_policy terminalia.ExternalOpenPolicy
---@field targets terminalia.ExternalOpenTarget[]
---@field pre_commands string[]
---@field commands string[]
---@field passthrough_args string[]
---@field diff boolean

---@param value string
---@return boolean
local function absolute_path(value)
    return value:sub(1, 1) == '/' or value:match('^%a:[/\\]') ~= nil
end

---@param cwd string
---@param path string
---@return string
local function resolve_path(cwd, path)
    if absolute_path(path) then
        return vim.fs.normalize(path)
    end

    return vim.fs.normalize(vim.fs.joinpath(cwd, path))
end

---@param value string
---@return string, integer?, integer?
local function split_position(value)
    local path, line, col = value:match('^(.-):(%d+):(%d+)$')

    if path ~= nil and path ~= '' then
        return path, tonumber(line), tonumber(col)
    end

    path, line = value:match('^(.-):(%d+)$')

    if path ~= nil and path ~= '' then
        return path, tonumber(line), nil
    end

    return value, nil, nil
end

---@param arg string
---@param cwd string
---@return terminalia.ExternalOpenTarget
local function parse_target(arg, cwd)
    if arg == '-' then
        return {
            raw = arg,
            stdin = true,
        }
    end

    local raw_path, line, col = split_position(arg)
    local path = resolve_path(cwd, raw_path)

    return {
        raw = arg,
        path = path,
        line = line,
        col = col,
        is_directory = vim.fn.isdirectory(path) == 1,
    }
end

---@param arg string
---@return integer?, integer?
local function parse_plus_position(arg)
    local line, col = arg:match('^%+(%d+):(%d+)$')

    if line ~= nil then
        return tonumber(line), tonumber(col)
    end

    line = arg:match('^%+(%d+)$')

    if line ~= nil then
        return tonumber(line), nil
    end
end

---@param plan terminalia.ExternalOpenPlan
---@param target terminalia.ExternalOpenTarget
---@param pending_line integer?
---@param pending_col integer?
local function append_target(plan, target, pending_line, pending_col)
    if target.line == nil and pending_line ~= nil then
        target.line = pending_line
        target.col = pending_col
    end

    table.insert(plan.targets, target)
end

---Parse an external editor invocation into a deterministic open plan.
---@param argv string[]
---@param opts? { cwd?: string, open_policy?: terminalia.ExternalOpenPolicy }
---@return terminalia.ExternalOpenPlan
function M.plan(argv, opts)
    opts = opts or {}

    local cwd = vim.fs.normalize(opts.cwd or vim.uv.cwd())
    local plan = {
        cwd = cwd,
        open_policy = config.normalize_external_open_policy(opts.open_policy),
        targets = {},
        pre_commands = {},
        commands = {},
        passthrough_args = {},
        diff = false,
    }
    local literal_args = false
    local pending_line
    local pending_col
    local pending_pre_command = false
    local pending_command = false

    for _, arg in ipairs(argv or {}) do
        if pending_pre_command then
            table.insert(plan.pre_commands, arg)
            pending_pre_command = false
        elseif pending_command then
            table.insert(plan.commands, arg)
            pending_command = false
        elseif not literal_args and arg == '--' then
            literal_args = true
        elseif not literal_args and arg == '--cmd' then
            pending_pre_command = true
        elseif not literal_args and vim.startswith(arg, '--cmd=') then
            table.insert(plan.pre_commands, arg:sub(7))
        elseif not literal_args and arg == '-c' then
            pending_command = true
        elseif not literal_args and vim.startswith(arg, '-c') and arg ~= '-c' then
            table.insert(plan.commands, arg:sub(3))
        elseif not literal_args and (arg == '-d' or arg == '--diff') then
            plan.diff = true
        elseif not literal_args and vim.startswith(arg, '+') then
            local line, col = parse_plus_position(arg)

            if line ~= nil then
                pending_line = line
                pending_col = col
            else
                table.insert(plan.commands, arg:sub(2))
            end
        elseif not literal_args and arg ~= '-' and vim.startswith(arg, '-') then
            table.insert(plan.passthrough_args, arg)
        else
            append_target(plan, parse_target(arg, cwd), pending_line, pending_col)
            pending_line = nil
            pending_col = nil
        end
    end

    return plan
end

return M

local config = require('terminalia.config')
local relay_args = require('terminalia.relay.args')

local M = {}

local parent_open_lua = [[
local payload = ...
local ok, api = pcall(require, 'terminalia.api')

if not ok then
    return {
        ok = false,
        error = tostring(api),
    }
end

local open_ok, result = pcall(api.open_external, payload.argv or {}, {
    cwd = payload.cwd,
    open_policy = payload.open_policy,
})

if not open_ok then
    return {
        ok = false,
        error = tostring(result),
    }
end

return {
    ok = true,
    opened = type(result) == 'table' and #result or 0,
}
]]

---@class terminalia.ParentRedirectTransport
---@field connect fun(address: string): integer?
---@field request fun(channel: integer, payload: terminalia.ParentRedirectPayload): table?
---@field close? fun(channel: integer)

---@class terminalia.ParentRedirectPayload
---@field argv string[]
---@field cwd string
---@field open_policy terminalia.ExternalOpenPolicy

---@class terminalia.ParentRedirectOptions
---@field argv? string[]
---@field cwd? string
---@field env? table<string, string>
---@field enabled? boolean
---@field open_policy? terminalia.ExternalOpenPolicy
---@field transport? terminalia.ParentRedirectTransport
---@field quit? fun()

---@class terminalia.ParentRedirectEnvOptions
---@field address? string
---@field enabled? boolean
---@field open_policy? terminalia.ExternalOpenPolicy

M.parent_env_var = 'TERMINALIA_PARENT_NVIM'
M.parent_kind_var = 'TERMINALIA_PARENT_KIND'
M.parent_policy_var = 'TERMINALIA_PARENT_OPEN_POLICY'
M.parent_kind = 'terminalia'

local blocked_flags = {
    ['--clean'] = true,
    ['--embed'] = true,
    ['--headless'] = true,
    ['--remote'] = true,
    ['--remote-expr'] = true,
    ['--remote-send'] = true,
    ['--remote-silent'] = true,
    ['--remote-tab'] = true,
    ['--remote-tab-silent'] = true,
    ['--remote-ui'] = true,
    ['--remote-wait'] = true,
    ['--remote-wait-silent'] = true,
    ['--remote-wait-tab'] = true,
    ['--remote-wait-tab-silent'] = true,
    ['-es'] = true,
}

local blocked_value_flags = {
    ['--cmd'] = true,
    ['--listen'] = true,
    ['--server'] = true,
    ['-S'] = true,
    ['-u'] = true,
}

---@param value any
---@return boolean
local function non_empty_string(value)
    return type(value) == 'string' and value ~= ''
end

---@param argv string[]
---@return string[]
local function copy_string_argv(argv)
    local copied = {}

    for _, arg in ipairs(argv or {}) do
        if type(arg) == 'string' then
            table.insert(copied, arg)
        end
    end

    return copied
end

---@return string[]
local function current_editor_args()
    local argv = copy_string_argv(vim.v.argv or {})

    if #argv > 0 then
        table.remove(argv, 1)
    end

    return argv
end

---@param argv string[]
---@return boolean
local function has_blocked_flags(argv)
    local literal_args = false

    for _, arg in ipairs(argv) do
        if not literal_args and arg == '--' then
            literal_args = true
        elseif not literal_args and blocked_flags[arg] then
            return true
        elseif not literal_args and blocked_value_flags[arg] then
            return true
        elseif not literal_args and (vim.startswith(arg, '--cmd=') or vim.startswith(arg, '--listen=')) then
            return true
        elseif not literal_args and vim.startswith(arg, '--remote') then
            return true
        end
    end

    return false
end

---@param argv string[]
---@param cwd string
---@param open_policy terminalia.ExternalOpenPolicy
---@return terminalia.ParentRedirectPayload?
local function safe_payload(argv, cwd, open_policy)
    if #argv == 0 or has_blocked_flags(argv) then
        return nil
    end

    local plan = relay_args.plan(argv, {
        cwd = cwd,
        open_policy = open_policy,
    })

    if #plan.targets == 0 then
        return nil
    end

    if plan.diff or #plan.pre_commands > 0 or #plan.commands > 0 or #plan.passthrough_args > 0 then
        return nil
    end

    for _, target in ipairs(plan.targets) do
        if target.stdin then
            return nil
        end
    end

    return {
        argv = copy_string_argv(argv),
        cwd = cwd,
        open_policy = plan.open_policy,
    }
end

---@return string?
function M.ensure_parent_server()
    if non_empty_string(vim.v.servername) then
        return vim.v.servername
    end

    local ok, address = pcall(vim.fn.serverstart)

    if ok and non_empty_string(address) then
        return address
    end

    return nil
end

---@param env table<string, string>?
---@param opts? terminalia.ParentRedirectEnvOptions
---@return table<string, string>?
function M.extend_child_env(env, opts)
    opts = opts or {}

    if opts.enabled == false or config.get().enable_parent_nvim_redirect ~= true then
        return env
    end

    local address = opts.address or M.ensure_parent_server()

    if not non_empty_string(address) then
        return env
    end

    local extended = vim.deepcopy(env or {})
    extended[M.parent_env_var] = address
    extended[M.parent_kind_var] = M.parent_kind
    extended[M.parent_policy_var] = opts.open_policy or config.get().external_open_policy

    return extended
end

---@return terminalia.ParentRedirectTransport
local function default_transport()
    return {
        connect = function(address)
            return vim.fn.sockconnect('pipe', address, {
                rpc = true,
            })
        end,
        request = function(channel, payload)
            return vim.fn.rpcrequest(channel, 'nvim_exec_lua', parent_open_lua, { payload })
        end,
        close = function(channel)
            pcall(vim.fn.chanclose, channel)
        end,
    }
end

---@param result any
---@return boolean
local function parent_open_succeeded(result)
    return type(result) == 'table' and result.ok == true
end

---@param opts? terminalia.ParentRedirectOptions
---@return boolean
function M.try_child_redirect(opts)
    opts = opts or {}

    if opts.enabled == false then
        return false
    end

    local env = opts.env or vim.env
    local address = env[M.parent_env_var]

    if env[M.parent_kind_var] ~= M.parent_kind or not non_empty_string(address) then
        return false
    end

    if non_empty_string(vim.v.servername) and vim.v.servername == address then
        return false
    end

    local open_policy = opts.open_policy or env[M.parent_policy_var] or config.get().external_open_policy
    local cwd = vim.fs.normalize(opts.cwd or vim.uv.cwd())
    local payload = safe_payload(copy_string_argv(opts.argv or current_editor_args()), cwd, open_policy)

    if payload == nil then
        return false
    end

    local transport = opts.transport or default_transport()
    local ok, channel = pcall(transport.connect, address)

    if not ok or type(channel) ~= 'number' or channel <= 0 then
        return false
    end

    local request_ok, result = pcall(transport.request, channel, payload)

    if type(transport.close) == 'function' then
        pcall(transport.close, channel)
    end

    if not request_ok or not parent_open_succeeded(result) then
        return false
    end

    if type(opts.quit) == 'function' then
        opts.quit()
    else
        vim.schedule(function()
            vim.cmd('silent! qa!')
        end)
    end

    return true
end

return M

local parse = require('terminalia.commands.parse')

local M = {}

---@param arglead string
---@param values string[]
---@return string[]
local function matching_values(arglead, values)
    local seen = {}
    local matches = {}

    for _, value in ipairs(values) do
        if value ~= nil and value ~= '' and not seen[value] and vim.startswith(value, arglead) then
            seen[value] = true
            table.insert(matches, value)
        end
    end

    table.sort(matches)

    return matches
end

---@param arglead string
---@param api table
---@return string[]
function M.terminal_id_completions(arglead, api)
    local ids = {}

    for _, terminal in ipairs(api.list()) do
        table.insert(ids, terminal.id)
    end

    return matching_values(arglead, ids)
end

---@param arglead string
---@param api table
---@return string[]
function M.namespace_completions(arglead, api)
    local namespaces = {}

    for _, terminal in ipairs(api.list()) do
        table.insert(namespaces, terminal.namespace)
    end

    return matching_values(arglead, namespaces)
end

---@param arglead string
---@param api table
---@return string[]
function M.context_id_completions(arglead, api)
    local ids = {}

    for _, context in ipairs(api.list_contexts()) do
        table.insert(ids, context.id)
    end

    return matching_values(arglead, ids)
end

---@param arglead string
---@param cmdline string
---@param api table
---@return string[]
function M.list_cwd_prefix_completions(arglead, cmdline, api)
    local prefixes = {}
    local namespace = parse.parsed_namespace_filter_from_args(parse.parse_cmdline_args(cmdline))

    for _, terminal in ipairs(api.list({ namespace = namespace })) do
        table.insert(prefixes, terminal.cwd)
    end

    return matching_values(arglead, prefixes)
end

---@param arglead string
---@return string[]
function M.view_completions(arglead)
    return matching_values(arglead, { 'split', 'float' })
end

return M

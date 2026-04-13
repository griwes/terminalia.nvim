local contexts = require('terminal_manager.contexts')

local M = {}

local SCHEME = 'terminal-manager://'

---@param value string
---@return string
local function encode_component(value)
    return (
        value:gsub('[%z\1-\31\127/%%?&=]', function(char)
            return string.format('%%%02X', string.byte(char))
        end)
    )
end

---@param value string
---@return string
local function decode_component(value)
    return (value:gsub('%%(%x%x)', function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

---@param context_id string
---@return string[]
local function context_stack_ids(context_id)
    local stack = {}
    local seen = {}
    local current_id = context_id

    while type(current_id) == 'string' and current_id ~= '' and not seen[current_id] do
        seen[current_id] = true
        table.insert(stack, 1, current_id)

        local context = contexts.get(current_id)

        if context == nil then
            break
        end

        current_id = context.parent_id
    end

    return stack
end

---@param params table<string, string>
---@return string
local function encode_query(params)
    local pieces = {}

    for _, key in ipairs({ 'context', 'stack' }) do
        local value = params[key]

        if type(value) == 'string' and value ~= '' then
            table.insert(pieces, string.format('%s=%s', key, encode_component(value)))
        end
    end

    if #pieces == 0 then
        return ''
    end

    return '?' .. table.concat(pieces, '&')
end

---@param query string?
---@return table<string, string>
local function decode_query(query)
    local params = {}

    if type(query) ~= 'string' or query == '' then
        return params
    end

    for pair in query:gmatch('[^&]+') do
        local key, value = pair:match('^([^=]+)=(.*)$')

        if key ~= nil and value ~= nil then
            params[key] = decode_component(value)
        end
    end

    return params
end

---@param kind 'terminal'|'history'
---@param terminal terminal_manager.TerminalRecord|{ id: string, name: string, context_id?: string }
---@return string
local function encode_uri(kind, terminal)
    local context_id = terminal.context_id or 'context:host'
    local stack_ids = context_stack_ids(context_id)

    return string.format(
        '%s%s/%s/%s%s',
        SCHEME,
        kind,
        terminal.id,
        encode_component(terminal.name),
        encode_query({
            context = context_id,
            stack = table.concat(stack_ids, ','),
        })
    )
end

---@param terminal terminal_manager.TerminalRecord
---@return string
function M.encode_terminal_uri(terminal)
    return encode_uri('terminal', terminal)
end

---@param terminal terminal_manager.TerminalRecord|{ id: string, name: string, context_id?: string }
---@return string
function M.encode_history_uri(terminal)
    return encode_uri('history', terminal)
end

---@param uri string
---@return { kind: string, terminal_id: string, name: string, context_id?: string, context_stack_ids: string[] }?, string?
function M.decode(uri)
    if type(uri) ~= 'string' or not vim.startswith(uri, SCHEME) then
        return nil, 'Unsupported terminal-manager URI'
    end

    local body = uri:sub(#SCHEME + 1)
    local path, query = body:match('^([^?]+)%??(.*)$')

    if path == nil then
        return nil, 'Malformed terminal-manager URI'
    end

    local kind, terminal_id, encoded_name = path:match('^([^/]+)/([^/]+)/(.+)$')

    if kind == nil or terminal_id == nil or encoded_name == nil then
        return nil, 'Malformed terminal-manager URI path'
    end

    if kind ~= 'terminal' and kind ~= 'history' then
        return nil, string.format('Unsupported terminal-manager URI kind: %s', kind)
    end

    local params = decode_query(query)
    local stack_ids = {}

    if params.stack ~= nil and params.stack ~= '' then
        stack_ids = vim.split(params.stack, ',', { plain = true, trimempty = true })
    end

    return {
        kind = kind,
        terminal_id = terminal_id,
        name = decode_component(encoded_name),
        context_id = params.context,
        context_stack_ids = stack_ids,
    }
end

M.encode_component = encode_component
M.decode_component = decode_component

return M

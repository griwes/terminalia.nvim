local contexts = require('terminalia.context.state')

local M = {}

local SCHEME = 'terminalia://'

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

---@param metadata? table<string, any>
---@return table<{ key: string, value: string }>
local function metadata_pairs(metadata)
    local items = {}

    if type(metadata) ~= 'table' then
        return items
    end

    for key, value in pairs(metadata) do
        local value_type = type(value)

        if type(key) == 'string' and (value_type == 'string' or value_type == 'number' or value_type == 'boolean') then
            table.insert(items, {
                key = key,
                value = tostring(value),
            })
        end
    end

    table.sort(items, function(left, right)
        return left.key < right.key
    end)

    return items
end

---@param context_id string
---@return terminalia.TerminalContext[]
local function context_stack(context_id)
    local stack = {}
    local seen = {}
    local current_id = context_id

    while type(current_id) == 'string' and current_id ~= '' and not seen[current_id] do
        seen[current_id] = true
        local context = contexts.get(current_id)

        if context == nil then
            table.insert(stack, 1, {
                id = current_id,
                kind = 'unknown',
                label = current_id,
                metadata = {},
            })
            break
        end

        table.insert(stack, 1, context)
        current_id = context.parent_id
    end

    return stack
end

---@param kind 'terminal'|'history'
---@param terminal terminalia.TerminalRecord|{ id: string, name: string, context_id?: string }
---@return string
local function encode_uri(kind, terminal)
    local context_id = terminal.context_id or 'context:host'
    local stack = context_stack(context_id)
    local segments = { kind, 'contexts' }

    for _, context in ipairs(stack) do
        table.insert(segments, 'context')
        table.insert(segments, encode_component(context.kind))
        table.insert(segments, encode_component(context.label))
        table.insert(segments, encode_component(context.id))

        for _, item in ipairs(metadata_pairs(context.metadata)) do
            table.insert(segments, 'meta')
            table.insert(segments, encode_component(item.key))
            table.insert(segments, encode_component(item.value))
        end
    end

    table.insert(segments, 'terminal')
    table.insert(segments, encode_component(terminal.id))
    table.insert(segments, encode_component(terminal.name))

    return SCHEME .. table.concat(segments, '/')
end

---@param terminal terminalia.TerminalRecord
---@return string
function M.encode_terminal_uri(terminal)
    return encode_uri('terminal', terminal)
end

---@param terminal terminalia.TerminalRecord|{ id: string, name: string, context_id?: string }
---@return string
function M.encode_history_uri(terminal)
    return encode_uri('history', terminal)
end

---@param segments string[]
---@param terminal_marker integer
---@return { kind: string, label: string, id: string, metadata: table<string, string> }[], string[]
local function decode_legacy_context_stack(segments, terminal_marker)
    local context_segments = terminal_marker - 3

    if context_segments < 0 or context_segments % 3 ~= 0 then
        error('Malformed Terminalia URI contexts')
    end

    local stack = {}
    local stack_ids = {}

    for index = 3, terminal_marker - 1, 3 do
        local context = {
            kind = decode_component(segments[index]),
            label = decode_component(segments[index + 1]),
            id = decode_component(segments[index + 2]),
            metadata = {},
        }

        table.insert(stack, context)
        table.insert(stack_ids, context.id)
    end

    return stack, stack_ids
end

---@param segments string[]
---@return integer?, { kind: string, label: string, id: string, metadata: table<string, string> }[], string[]?, string?
local function decode_context_stack(segments)
    local stack = {}
    local stack_ids = {}
    local index = 3

    if segments[index] ~= 'context' then
        local legacy_terminal_marker

        for legacy_index = 3, #segments do
            if segments[legacy_index] == 'terminal' then
                legacy_terminal_marker = legacy_index
                break
            end
        end

        if legacy_terminal_marker == nil or legacy_terminal_marker + 2 ~= #segments then
            return nil, nil, nil, 'Malformed Terminalia URI path'
        end

        local ok, legacy_stack, legacy_ids = pcall(decode_legacy_context_stack, segments, legacy_terminal_marker)

        if not ok then
            return nil, nil, nil, legacy_stack
        end

        return legacy_terminal_marker, legacy_stack, legacy_ids
    end

    while index <= #segments do
        if segments[index] == 'terminal' then
            return index, stack, stack_ids
        end

        if segments[index] ~= 'context' or index + 3 > #segments then
            return nil, nil, nil, 'Malformed Terminalia URI path'
        end

        local context = {
            kind = decode_component(segments[index + 1]),
            label = decode_component(segments[index + 2]),
            id = decode_component(segments[index + 3]),
            metadata = {},
        }

        index = index + 4

        while index <= #segments and segments[index] == 'meta' do
            if index + 2 > #segments then
                return nil, nil, nil, 'Malformed Terminalia URI metadata'
            end

            context.metadata[decode_component(segments[index + 1])] = decode_component(segments[index + 2])
            index = index + 3
        end

        table.insert(stack, context)
        table.insert(stack_ids, context.id)
    end

    return nil, nil, nil, 'Malformed Terminalia URI path'
end

---@param uri_value string
---@return { kind: string, terminal_id: string, name: string, context_id?: string, context_stack: { kind: string, label: string, id: string, metadata: table<string, string> }[], context_stack_ids: string[] }?, string?
function M.decode(uri_value)
    if type(uri_value) ~= 'string' or not vim.startswith(uri_value, SCHEME) then
        return nil, 'Unsupported Terminalia URI'
    end

    local body = uri_value:sub(#SCHEME + 1)
    local segments = vim.split(body, '/', { plain = true, trimempty = true })

    if #segments < 5 then
        return nil, 'Malformed Terminalia URI'
    end

    local kind = segments[1]

    if kind ~= 'terminal' and kind ~= 'history' then
        return nil, string.format('Unsupported Terminalia URI kind: %s', kind)
    end

    if segments[2] ~= 'contexts' then
        return nil, 'Malformed Terminalia URI path'
    end

    local terminal_marker, stack, stack_ids, err = decode_context_stack(segments)

    if terminal_marker == nil then
        return nil, err
    end

    if terminal_marker + 2 ~= #segments then
        return nil, 'Malformed Terminalia URI path'
    end

    return {
        kind = kind,
        terminal_id = decode_component(segments[terminal_marker + 1]),
        name = decode_component(segments[terminal_marker + 2]),
        context_id = stack[#stack] and stack[#stack].id or nil,
        context_stack = stack,
        context_stack_ids = stack_ids,
    }
end

M.encode_component = encode_component
M.decode_component = decode_component

return M

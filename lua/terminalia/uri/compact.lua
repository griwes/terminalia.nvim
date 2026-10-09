local components = require('terminalia.uri.components')
local contexts = require('terminalia.context.state')
local model = require('terminalia.terminal.model')

local M = {}

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

---@param context terminalia.TerminalContext
---@return string
local function encode_context(context)
    local parts = { components.encode(context.kind) .. ':' .. components.encode_id(context.id, 'context:') }

    if context.label ~= context.id then
        table.insert(parts, 'label=' .. components.encode(context.label))
    end

    local keys = vim.tbl_keys(context.metadata or {})
    table.sort(keys, function(left, right)
        return tostring(left) < tostring(right)
    end)

    for _, key in ipairs(keys) do
        local value = context.metadata[key]
        local value_type = type(value)

        if type(key) == 'string' and (value_type == 'string' or value_type == 'number' or value_type == 'boolean') then
            table.insert(parts, 'meta.' .. components.encode(key) .. '=' .. components.encode(tostring(value)))
        end
    end

    return table.concat(parts, ';')
end

---@param kind 'terminal'|'history'
---@param terminal terminalia.TerminalRecord|{ id: string, name: string, context_id?: string }
---@return string
function M.encode(kind, terminal)
    local segments = {}

    for _, context in ipairs(context_stack(terminal.context_id or contexts.host().id)) do
        if context.kind ~= 'host' and context.id ~= contexts.host().id then
            table.insert(segments, encode_context(context))
        end
    end

    local terminal_id = components.encode_id(terminal.id, 'terminal:')

    if terminal_id == 'history' then
        terminal_id = '%68istory'
    end

    table.insert(segments, terminal_id)

    if kind == 'history' then
        table.insert(segments, 'history')
    end

    local path = table.concat(segments, '/')

    if terminal.name ~= terminal.id then
        path = path .. '?name=' .. components.encode(terminal.name)
    end

    return path
end

---@param segment string
---@return terminalia.UriContext?, string?
local function decode_context(segment)
    local parts = vim.split(segment, ';', { plain = true })
    local kind, id = parts[1]:match('^([^:]+):(.+)$')

    if kind == nil or id == nil then
        return nil, 'Malformed Terminalia URI context'
    end

    local decoded_id = components.decode_id(id, 'context:')
    local context = {
        kind = components.decode(kind),
        id = decoded_id,
        label = decoded_id,
        metadata = {},
    }
    local seen = {}

    if context.kind == 'host' or not model.is_valid_id(context.id) then
        return nil, 'Malformed Terminalia URI context'
    end

    for index = 2, #parts do
        local key, value = parts[index]:match('^([^=]+)=(.*)$')

        if key == nil or seen[key] then
            return nil, 'Malformed Terminalia URI metadata'
        end

        seen[key] = true

        if key == 'label' then
            context.label = components.decode(value)
        elseif vim.startswith(key, 'meta.') and #key > 5 then
            local metadata_key = components.decode(key:sub(6))

            if context.metadata[metadata_key] ~= nil then
                return nil, 'Malformed Terminalia URI metadata'
            end

            context.metadata[metadata_key] = components.decode(value)
        else
            return nil, 'Malformed Terminalia URI metadata'
        end
    end

    return context
end

---@param body string
---@return terminalia.DecodedUri?, string?
function M.decode(body)
    if body == '' or not components.valid_encoding(body) or body:find('#', 1, true) then
        return nil, 'Malformed Terminalia URI'
    end

    local path, query = body:match('^([^?]*)%?(.*)$')
    path = path or body
    local segments = vim.split(path, '/', { plain = true })
    local kind = 'terminal'

    if #segments > 1 and segments[#segments] == 'history' then
        kind = 'history'
        table.remove(segments)
    end

    for _, segment in ipairs(segments) do
        if segment == '' then
            return nil, 'Malformed Terminalia URI path'
        end
    end

    local terminal_segment = table.remove(segments)

    if terminal_segment:find(';', 1, true) then
        return nil, 'Malformed Terminalia URI path'
    end

    local terminal_id = components.decode_id(terminal_segment, 'terminal:')

    if not model.is_valid_id(terminal_id) then
        return nil, 'Malformed Terminalia URI terminal id'
    end

    local name = terminal_id

    if query ~= nil then
        local value = query:match('^name=(.*)$')

        if value == nil or value:find('[?&=]') then
            return nil, 'Malformed Terminalia URI query'
        end

        name = components.decode(value)
    end

    local host = contexts.host()
    local stack = { { id = host.id, kind = host.kind, label = host.label, metadata = {} } }
    local stack_ids = { host.id }
    local seen = { [host.id] = true }

    for _, segment in ipairs(segments) do
        local context, err = decode_context(segment)

        if context == nil then
            return nil, err
        end

        if seen[context.id] then
            return nil, 'Malformed Terminalia URI context stack'
        end

        seen[context.id] = true
        table.insert(stack, context)
        table.insert(stack_ids, context.id)
    end

    return {
        kind = kind,
        terminal_id = terminal_id,
        name = name,
        context_id = stack[#stack].id,
        context_stack = stack,
        context_stack_ids = stack_ids,
    }
end

return M

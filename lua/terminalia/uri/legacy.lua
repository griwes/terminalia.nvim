local components = require('terminalia.uri.components')

local M = {}

---@param segments string[]
---@param terminal_marker integer
---@return terminalia.UriContext[], string[]
local function decode_context_stack(segments, terminal_marker)
    local context_segments = terminal_marker - 3

    if context_segments < 0 or context_segments % 3 ~= 0 then
        error('Malformed Terminalia URI contexts')
    end

    local stack = {}
    local stack_ids = {}

    for index = 3, terminal_marker - 1, 3 do
        local context = {
            kind = components.decode(segments[index]),
            label = components.decode(segments[index + 1]),
            id = components.decode(segments[index + 2]),
            metadata = {},
        }

        table.insert(stack, context)
        table.insert(stack_ids, context.id)
    end

    return stack, stack_ids
end

---@param segments string[]
---@return integer?, terminalia.UriContext[]?, string[]?, string?
local function decode_context_stack_at_end(segments)
    local terminal_marker = #segments - 2

    if terminal_marker < 3 or segments[terminal_marker] ~= 'terminal' then
        return nil, nil, nil, 'Malformed Terminalia URI path'
    end

    local ok, stack, stack_ids = pcall(decode_context_stack, segments, terminal_marker)

    if not ok then
        return nil, nil, nil, stack
    end

    return terminal_marker, stack, stack_ids
end

---@param segments string[]
---@return integer?, terminalia.UriContext[]?, string[]?, string?
local function decode_marker_context_stack(segments)
    local stack = {}
    local stack_ids = {}
    local index = 3

    while index <= #segments do
        if segments[index] == 'terminal' then
            return index, stack, stack_ids
        end

        if segments[index] ~= 'context' or index + 3 > #segments then
            return nil, nil, nil, 'Malformed Terminalia URI path'
        end

        local context = {
            kind = components.decode(segments[index + 1]),
            label = components.decode(segments[index + 2]),
            id = components.decode(segments[index + 3]),
            metadata = {},
        }
        index = index + 4

        while index <= #segments and segments[index] == 'meta' do
            if index + 2 > #segments then
                return nil, nil, nil, 'Malformed Terminalia URI metadata'
            end

            context.metadata[components.decode(segments[index + 1])] = components.decode(segments[index + 2])
            index = index + 3
        end

        table.insert(stack, context)
        table.insert(stack_ids, context.id)
    end

    return nil, nil, nil, 'Malformed Terminalia URI path'
end

---@param segments string[]
---@return integer?, terminalia.UriContext[]?, string[]?, string?
local function decode_stack(segments)
    if segments[3] ~= 'context' then
        return decode_context_stack_at_end(segments)
    end

    local terminal_marker, stack, stack_ids, err = decode_marker_context_stack(segments)

    if terminal_marker ~= nil and terminal_marker + 2 == #segments then
        return terminal_marker, stack, stack_ids
    end

    local marker_err = terminal_marker ~= nil and 'Malformed Terminalia URI path' or err
    local legacy_terminal_marker, legacy_stack, legacy_ids = decode_context_stack_at_end(segments)

    if legacy_terminal_marker ~= nil then
        return legacy_terminal_marker, legacy_stack, legacy_ids
    end

    return nil, nil, nil, marker_err
end

---@param body string
---@return terminalia.DecodedUri?, string?
function M.decode(body)
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

    local terminal_marker, stack, stack_ids, err = decode_stack(segments)

    if terminal_marker == nil then
        return nil, err
    end

    if terminal_marker + 2 ~= #segments then
        return nil, 'Malformed Terminalia URI path'
    end

    return {
        kind = kind,
        terminal_id = components.decode(segments[terminal_marker + 1]),
        name = components.decode(segments[terminal_marker + 2]),
        context_id = stack[#stack] and stack[#stack].id or nil,
        context_stack = stack,
        context_stack_ids = stack_ids,
    }
end

return M

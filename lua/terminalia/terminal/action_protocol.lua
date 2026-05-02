local M = {}

local prefix = '\027]777;terminalia;open;'
local terminator = '\007'

---@class terminalia.TerminalActionStripState
---@field pending string?

---@class terminalia.TerminalAction
---@field kind 'open'
---@field payload table
---@field sequence string

---@param value string
---@return string
local function strip_terminator(value)
    if vim.endswith(value, '\007') then
        return value:sub(1, -2)
    end

    if vim.endswith(value, '\027\\') then
        return value:sub(1, -3)
    end

    return value
end

---@param value string
---@param start integer
---@return integer?, integer?
local function find_terminator(value, start)
    local bel_start = value:find('\007', start, true)
    local st_start = value:find('\027\\', start, true)

    if bel_start == nil then
        if st_start == nil then
            return nil, nil
        end

        return st_start, st_start + 1
    end

    if st_start == nil or bel_start < st_start then
        return bel_start, bel_start
    end

    return st_start, st_start + 1
end

---@param value string
---@return string, string?
local function split_partial_prefix(value)
    local max_prefix_len = math.min(#prefix - 1, #value)

    for length = max_prefix_len, 1, -1 do
        if value:sub(-length) == prefix:sub(1, length) then
            return value:sub(1, #value - length), value:sub(-length)
        end
    end

    return value, nil
end

---@param sequence string
---@return terminalia.TerminalAction?
function M.parse_sequence(sequence)
    if type(sequence) ~= 'string' or not vim.startswith(sequence, prefix) then
        return nil
    end

    local payload = strip_terminator(sequence:sub(#prefix + 1))
    local ok, decoded = pcall(vim.json.decode, payload)

    if not ok or type(decoded) ~= 'table' then
        return nil
    end

    return {
        kind = 'open',
        payload = decoded,
        sequence = sequence,
    }
end

---@param payload table
---@return string
function M.open_sequence(payload)
    assert(type(payload) == 'table', 'Terminalia open action payload must be a table')

    return prefix .. vim.json.encode(payload) .. terminator
end

---@return string, string
function M.open_sequence_parts()
    return prefix, terminator
end

---@param sequence string
---@return table?
function M.parse_open_sequence(sequence)
    local action = M.parse_sequence(sequence)

    if action == nil or action.kind ~= 'open' then
        return nil
    end

    return action.payload
end

---@return terminalia.TerminalActionStripState
function M.new_strip_state()
    return {}
end

---@param value string
---@param state terminalia.TerminalActionStripState
---@param actions terminalia.TerminalAction[]
---@return string
local function extract_action_sequences(value, state, actions)
    local source = (state.pending or '') .. value
    state.pending = nil

    local output = {}
    local cursor = 1

    while cursor <= #source do
        local action_start = source:find(prefix, cursor, true)

        if action_start == nil then
            local remainder, pending = split_partial_prefix(source:sub(cursor))
            table.insert(output, remainder)
            state.pending = pending
            break
        end

        table.insert(output, source:sub(cursor, action_start - 1))

        local _, action_end = find_terminator(source, action_start + #prefix)

        if action_end == nil then
            state.pending = source:sub(action_start)
            break
        end

        cursor = action_end + 1
        local action = M.parse_sequence(source:sub(action_start, action_end))

        if action ~= nil then
            table.insert(actions, action)
        end
    end

    return table.concat(output)
end

---@param chunks string[]?
---@param state? terminalia.TerminalActionStripState
---@return string[]?
---@return terminalia.TerminalAction[]
function M.extract_action_chunks(chunks, state)
    local actions = {}

    if type(chunks) ~= 'table' then
        return chunks, actions
    end

    state = state or M.new_strip_state()

    local stripped = {}

    for _, chunk in ipairs(chunks) do
        if type(chunk) == 'string' then
            chunk = extract_action_sequences(chunk, state, actions)
        end

        if chunk ~= '' then
            table.insert(stripped, chunk)
        end
    end

    return stripped, actions
end

---@param chunks string[]?
---@param state? terminalia.TerminalActionStripState
---@return string[]?
function M.strip_action_chunks(chunks, state)
    local stripped = M.extract_action_chunks(chunks, state)
    return stripped
end

return M

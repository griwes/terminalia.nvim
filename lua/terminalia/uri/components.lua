local M = {}

---@param value string
---@return string
function M.encode(value)
    return (value:gsub('[^%w%-%._~]', function(char)
        return string.format('%%%02X', string.byte(char))
    end))
end

---@param value string
---@return string
function M.decode(value)
    return (value:gsub('%%(%x%x)', function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

---@param value string
---@return boolean
function M.valid_encoding(value)
    return value:gsub('%%%x%x', ''):find('%', 1, true) == nil
end

---@param id string
---@param prefix string
---@return string
function M.encode_id(id, prefix)
    local suffix = id:sub(1, #prefix) == prefix and id:sub(#prefix + 1) or ''

    if suffix ~= '' then
        return M.encode(suffix)
    end

    return '@' .. M.encode(id)
end

---@param value string
---@param prefix string
---@return string
function M.decode_id(value, prefix)
    if value:sub(1, 1) == '@' then
        return M.decode(value:sub(2))
    end

    return prefix .. M.decode(value)
end

return M

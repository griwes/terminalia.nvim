local compact = require('terminalia.uri.compact')
local components = require('terminalia.uri.components')
local legacy = require('terminalia.uri.legacy')

local M = {}

---@class terminalia.UriContext
---@field kind string
---@field label string
---@field id string
---@field metadata table<string, string>

---@class terminalia.DecodedUri
---@field kind 'terminal'|'history'
---@field terminal_id string
---@field name string
---@field context_id? string
---@field context_stack terminalia.UriContext[]
---@field context_stack_ids string[]

local SCHEME = 'terminalia://'
local LEGACY_SCHEME = 'terminal-manager://'

---@param terminal terminalia.TerminalRecord
---@return string
function M.encode_terminal_uri(terminal)
    return SCHEME .. compact.encode('terminal', terminal)
end

---@param terminal terminalia.TerminalRecord|{ id: string, name: string, context_id?: string }
---@return string
function M.encode_history_uri(terminal)
    return SCHEME .. compact.encode('history', terminal)
end

---@param uri_value string
---@return terminalia.DecodedUri?, string?
function M.decode(uri_value)
    if type(uri_value) ~= 'string' then
        return nil, 'Unsupported Terminalia URI'
    end

    if vim.startswith(uri_value, LEGACY_SCHEME) then
        return legacy.decode(uri_value:sub(#LEGACY_SCHEME + 1))
    end

    if not vim.startswith(uri_value, SCHEME) then
        return nil, 'Unsupported Terminalia URI'
    end

    local body = uri_value:sub(#SCHEME + 1)

    if body:match('^terminal/contexts/') or body:match('^history/contexts/') then
        return legacy.decode(body)
    end

    return compact.decode(body)
end

M.encode_component = components.encode
M.decode_component = components.decode

return M

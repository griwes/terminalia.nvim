local context_providers = require('terminalia.context.providers')
local contexts = require('terminalia.context.state')
local config = require('terminalia.config')
local float_view = require('terminalia.view.float')
local history_view = require('terminalia.view.history')
local split_view = require('terminalia.view.split')
local uri = require('terminalia.uri')

local M = {}

local openers = {
    split = split_view.open,
    float = float_view.open,
}

---@param terminal terminalia.TerminalRecord
---@param opts? { view?: terminalia.ViewKind }
---@return terminalia.ViewKind
local function resolve_view(terminal, opts)
    local view = opts and opts.view or terminal.preferred_view or config.get().default_view

    if openers[view] == nil then
        error(string.format('Unsupported terminal view: %s', view))
    end

    return view
end

---@param terminal terminalia.TerminalRecord
---@param view terminalia.ViewKind
---@param opts? { start_insert?: boolean }
local function reveal(terminal, view, opts)
    return openers[view](terminal, config.get(), opts)
end

---@param api table
---@param uri_value string
---@return { kind: string, terminal_id: string, name: string, context_id?: string, context_stack_ids: string[] }?, string?
function M.decode_uri(api, uri_value)
    return uri.decode(uri_value)
end

---@param api table
---@param uri_value string
---@param opts? { view?: terminalia.ViewKind, start_insert?: boolean }
---@return integer|terminalia.TerminalRecord
function M.open_uri(api, uri_value, opts)
    local decoded, err = uri.decode(uri_value)

    if decoded == nil then
        error(assert(err))
    end

    if decoded.context_id ~= nil then
        local restored_context = contexts.get(decoded.context_id)

        if restored_context == nil and decoded.context_stack ~= nil and #decoded.context_stack > 0 then
            restored_context = context_providers.restore_context_stack(decoded.context_stack)
        end

        if restored_context ~= nil then
            contexts.set_current(restored_context.id)
        end
    end

    if decoded.kind == 'history' then
        return api.open_history(decoded.terminal_id)
    end

    return api.open(decoded.terminal_id, opts)
end

---@param api table
---@param id string
---@param opts? { view?: terminalia.ViewKind, start_insert?: boolean }
---@return terminalia.TerminalRecord
function M.open_terminal(api, id, opts)
    local terminal = assert(api.get(id), string.format('Unknown terminal id: %s', id))
    local view = resolve_view(terminal, opts)

    api.start(id)
    reveal(terminal, view, opts)

    return api.update(id, {
        last_opened_at = os.time(),
        preferred_view = view,
    })
end

return M

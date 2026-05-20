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

---@param decoded table
local function restore_context(decoded)
    if decoded.context_id == nil then
        return
    end

    local restored_context = contexts.get(decoded.context_id)

    if restored_context == nil and decoded.context_stack ~= nil and #decoded.context_stack > 0 then
        restored_context = context_providers.restore_context_stack(decoded.context_stack)
    end

    if restored_context ~= nil then
        contexts.set_current(restored_context.id)
    end
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

    restore_context(decoded)

    if decoded.kind == 'history' then
        return api.open_history(decoded.terminal_id)
    end

    return api.open(decoded.terminal_id, opts)
end

---@param api table
---@param decoded table
---@return terminalia.TerminalRecord
local function ensure_uri_terminal_record(api, decoded)
    local terminal = api.get(decoded.terminal_id)

    if terminal ~= nil then
        return terminal
    end

    return api.create({
        id = decoded.terminal_id,
        name = decoded.name,
        context_id = decoded.context_id,
    })
end

---@param bufnr integer
---@return boolean
local function buffer_is_visible(bufnr)
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
            return true
        end
    end

    return false
end

---@param replacement integer
---@param obsolete integer
local function replace_current_buffer(replacement, obsolete)
    vim.api.nvim_win_set_buf(0, replacement)

    if obsolete ~= replacement and vim.api.nvim_buf_is_valid(obsolete) then
        pcall(vim.api.nvim_buf_delete, obsolete, { force = true })
    end
end

---@param api table
---@param bufnr integer
---@param decoded table
---@return terminalia.TerminalRecord
local function adopt_terminal_buffer(api, bufnr, decoded)
    local terminal = ensure_uri_terminal_record(api, decoded)

    if terminal.bufnr ~= nil and vim.api.nvim_buf_is_valid(terminal.bufnr) and terminal.bufnr ~= bufnr then
        replace_current_buffer(terminal.bufnr, bufnr)
        require('terminalia.winbar').install(terminal.bufnr)
        return terminal
    end

    vim.bo[bufnr].bufhidden = 'hide'
    vim.bo[bufnr].swapfile = false
    vim.b[bufnr].terminalia_id = terminal.id
    terminal = api.update(terminal.id, {
        bufnr = bufnr,
    })
    require('terminalia.winbar').install(bufnr)

    if buffer_is_visible(bufnr) and not (terminal.status == 'running' and terminal.job_id ~= nil) then
        terminal = api.start(terminal.id)
    end

    return terminal
end

---@param api table
---@param bufnr integer
---@param decoded table
---@return integer
local function adopt_history_buffer(api, bufnr, decoded)
    local terminal = ensure_uri_terminal_record(api, decoded)
    local ok, lines = pcall(api.history_lines, terminal.id)

    if not ok or type(lines) ~= 'table' or #lines == 0 then
        lines = { '' }
    end

    vim.bo[bufnr].buftype = 'nofile'
    vim.bo[bufnr].bufhidden = 'wipe'
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].filetype = 'terminaliahistory'
    vim.b[bufnr].terminalia_history_view = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].modified = false

    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
            vim.wo[winid].wrap = false
            vim.wo[winid].number = false
            vim.wo[winid].relativenumber = false
            vim.api.nvim_win_set_cursor(winid, { math.max(1, vim.api.nvim_buf_line_count(bufnr)), 0 })
        end
    end

    return bufnr
end

---@param api table
---@param bufnr integer
---@param opts? table
---@return terminalia.TerminalRecord|integer|nil
function M.adopt_uri_buffer(api, bufnr, opts)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local decoded, err = uri.decode(vim.api.nvim_buf_get_name(bufnr))

    if decoded == nil then
        if opts ~= nil and opts.raise == true then
            error(assert(err))
        end
        return nil
    end

    restore_context(decoded)

    if decoded.kind == 'history' then
        return adopt_history_buffer(api, bufnr, decoded)
    end

    return adopt_terminal_buffer(api, bufnr, decoded)
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

local contexts = require('terminalia.context.state')
local registry = require('terminalia.terminal.registry')

---@class terminalia.WinbarModule
local M = {}

local SIGIL = ''
local EXPRESSION = "%!v:lua.require'terminalia.winbar'.render()"

---@param value string?
---@param max_width integer
---@return string?
local function shorten_left(value, max_width)
    if value == nil or value == '' then
        return nil
    end

    if vim.fn.strdisplaywidth(value) <= max_width then
        return value
    end

    local marker = '…'
    local width = vim.fn.strdisplaywidth(marker)
    local output = {}

    for index = #value, 1, -1 do
        local char = value:sub(index, index)
        width = width + vim.fn.strdisplaywidth(char)

        if width > max_width then
            break
        end

        table.insert(output, 1, char)
    end

    return marker .. table.concat(output, '')
end

---@param command terminalia.TerminalCommand?
---@return string?
local function command_text(command)
    if type(command) == 'string' then
        return command
    end

    if type(command) == 'table' then
        return table.concat(command, ' ')
    end

    return nil
end

---@param terminal terminalia.TerminalRecord
---@return statuesque.RenderSpec[]
local function render_parts(terminal)
    local status_hl = terminal.status == 'running' and 'DiagnosticOk' or 'DiagnosticWarn'
    local cwd = shorten_left(terminal.cwd, 48)
    local command = shorten_left(command_text(terminal.command), 40)
    local context = contexts.get(terminal.context_id)
    local parts = {
        { text = 'Terminalia', role = 'terminalia.label', hl = 'Type' },
        { text = ' ' .. terminal.name, role = 'terminalia.name', hl = 'Identifier' },
        { text = ' ' .. terminal.status, role = 'terminalia.status', hl = status_hl },
    }

    if terminal.exit_code ~= nil then
        table.insert(parts, {
            text = string.format(' exit=%d', terminal.exit_code),
            role = 'terminalia.exit_code',
            hl = terminal.exit_code == 0 and 'DiagnosticOk' or 'DiagnosticError',
        })
    end

    if context ~= nil and context.id ~= 'context:host' then
        table.insert(parts, {
            text = ' ' .. context.label,
            role = 'terminalia.context',
            hl = 'Special',
        })
    end

    if command ~= nil then
        table.insert(parts, {
            text = ' ' .. command,
            role = 'terminalia.command',
            hl = 'Comment',
        })
    end

    if cwd ~= nil then
        table.insert(parts, {
            text = ' ' .. cwd,
            role = 'terminalia.cwd',
            hl = 'Directory',
        })
    end

    return parts
end

---@param terminal terminalia.TerminalRecord
---@return statuesque.RenderSpec
local function render_spec(terminal)
    return {
        left = {
            {
                role = 'terminalia',
                children = render_parts(terminal),
            },
        },
    }
end

---@param winid integer?
---@return integer
local function resolve_window(winid)
    winid = tonumber(winid or vim.g.statusline_winid)

    if winid ~= nil and vim.api.nvim_win_is_valid(winid) then
        return winid
    end

    return vim.api.nvim_get_current_win()
end

---@param bufnr integer
---@return terminalia.TerminalRecord?
local function terminal_for_buffer(bufnr)
    local terminal_id = vim.b[bufnr].terminalia_id

    if type(terminal_id) ~= 'string' then
        return nil
    end

    return registry.get(terminal_id)
end

---@param terminal terminalia.TerminalRecord
---@return string
local function fallback_text(terminal)
    local parts = {
        'Terminalia',
        terminal.name,
        terminal.status,
    }

    if terminal.exit_code ~= nil then
        parts[#parts + 1] = string.format('exit=%d', terminal.exit_code)
    end

    if terminal.cwd ~= nil and terminal.cwd ~= '' then
        parts[#parts + 1] = terminal.cwd
    end

    return table.concat(parts, '  ')
end

---@return string
function M.expression()
    return EXPRESSION
end

---@param winid? integer
---@return string
function M.render(winid)
    winid = resolve_window(winid)

    local terminal = terminal_for_buffer(vim.api.nvim_win_get_buf(winid))

    if terminal == nil then
        return ''
    end

    local ok, statuesque = pcall(require, 'statuesque')

    if not ok then
        return fallback_text(terminal)
    end

    local composed = statuesque.compose(render_spec(terminal), {
        surface = 'winbar',
        sigil = SIGIL,
    })

    return statuesque.render(composed, 'winbar', {
        surface = 'winbar',
        winid = winid,
    })
end

---@param bufnr integer
function M.install(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local ok, statuesque = pcall(require, 'statuesque')

    if ok then
        statuesque.replace_window_surface({
            owner = 'terminalia',
            target = 'winbar',
            bufnr = bufnr,
            expression = EXPRESSION,
            all_windows = true,
        })
        return
    end

    local terminal = terminal_for_buffer(bufnr)
    local winbar = terminal ~= nil and fallback_text(terminal) or EXPRESSION

    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
            vim.wo[winid].winbar = winbar
        end
    end
end

return M

local M = {}

local registered = false
local view_kinds = { 'split', 'float' }

---@param args string
---@return string[]
local function split_args(args)
    return vim.split(vim.trim(args), ' ', { trimempty = true })
end

---@param arglead string
---@param values string[]
---@return string[]
local function matching_values(arglead, values)
    local seen = {}
    local matches = {}

    for _, value in ipairs(values) do
        if value ~= nil and value ~= '' and not seen[value] and vim.startswith(value, arglead) then
            seen[value] = true
            table.insert(matches, value)
        end
    end

    table.sort(matches)

    return matches
end

---@param arglead string
---@param api table
---@return string[]
local function terminal_id_completions(arglead, api)
    local ids = {}

    for _, terminal in ipairs(api.list()) do
        table.insert(ids, terminal.id)
    end

    return matching_values(arglead, ids)
end

---@param arglead string
---@param api table
---@return string[]
local function namespace_completions(arglead, api)
    local namespaces = {}

    for _, terminal in ipairs(api.list()) do
        table.insert(namespaces, terminal.namespace)
    end

    return matching_values(arglead, namespaces)
end

---@param arglead string
---@param api table
---@return string[]
local function cwd_prefix_completions(arglead, api)
    local prefixes = {}

    for _, terminal in ipairs(api.list()) do
        table.insert(prefixes, terminal.cwd)
    end

    return matching_values(arglead, prefixes)
end

---@param arglead string
---@return string[]
local function view_completions(arglead)
    return matching_values(arglead, view_kinds)
end

---@param cmdline string
---@return string[]
local function command_args(cmdline)
    local stripped = cmdline:gsub('^:?%S+%s*', '', 1)
    local args = split_args(stripped)

    if cmdline:sub(-1):match('%s') then
        table.insert(args, '')
    end

    return args
end

---@param verb string
---@param terminal terminal_manager.TerminalRecord
local function notify_terminal(verb, terminal)
    vim.notify(string.format('%s %s (%s)', verb, terminal.id, terminal.name))
end

---Register the plugin's user commands once.
---@param terminal_manager terminal_manager.RootModule
function M.ensure(terminal_manager)
    if registered then
        return
    end

    local function new_terminal_command(command_opts)
        local args = split_args(command_opts.args)

        local terminal = terminal_manager.api.create_and_open({
            name = args[1],
            namespace = args[2],
            view = args[3],
        })

        notify_terminal('Opened', terminal)
    end

    local function open_terminal_command(command_opts)
        local args = split_args(command_opts.args)

        if #args == 0 then
            error('TerminalManagerOpen requires a terminal id')
        end

        local terminal = terminal_manager.api.open(args[1], {
            view = args[2],
        })

        notify_terminal('Revealed', terminal)
    end

    local function list_terminals_command(command_opts)
        local args = split_args(command_opts.args)
        local lines = terminal_manager.api.list_lines({
            namespace = args[1],
            cwd_prefix = args[2],
        })

        if #lines == 0 then
            if #args > 0 then
                vim.notify('No terminals matched the requested filters')
                return
            end

            vim.notify('No terminals registered')
            return
        end

        vim.notify(table.concat(lines, '\n'))
    end

    local function history_command(command_opts)
        local args = split_args(command_opts.args)

        if #args == 0 then
            error('TerminalManagerHistory requires a terminal id')
        end

        terminal_manager.api.open_history(args[1])
    end

    vim.api.nvim_create_user_command('TerminalManagerNew', new_terminal_command, {
        nargs = '*',
        desc = 'Create and reveal a terminal: [name] [namespace] [view]',
        complete = function(arglead, cmdline)
            local args = command_args(cmdline)

            if #args == 2 then
                return namespace_completions(arglead, terminal_manager.api)
            end

            if #args >= 3 then
                return view_completions(arglead)
            end

            return {}
        end,
    })

    vim.api.nvim_create_user_command('TerminalManagerOpen', open_terminal_command, {
        nargs = '+',
        desc = 'Reveal an existing terminal: <id> [view]',
        complete = function(arglead, cmdline)
            local args = command_args(cmdline)

            if #args <= 1 then
                return terminal_id_completions(arglead, terminal_manager.api)
            end

            return view_completions(arglead)
        end,
    })

    vim.api.nvim_create_user_command('TerminalManagerList', list_terminals_command, {
        nargs = '*',
        desc = 'List registered terminals: [namespace] [cwd_prefix]',
        complete = function(arglead, cmdline)
            local args = command_args(cmdline)

            if #args <= 1 then
                return namespace_completions(arglead, terminal_manager.api)
            end

            return cwd_prefix_completions(arglead, terminal_manager.api)
        end,
    })

    vim.api.nvim_create_user_command('TerminalManagerHistory', history_command, {
        nargs = 1,
        desc = 'Open captured history for a terminal: <id>',
        complete = function(arglead)
            return terminal_id_completions(arglead, terminal_manager.api)
        end,
    })

    registered = true
end

return M

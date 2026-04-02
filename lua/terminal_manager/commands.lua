local M = {}

local registered = false

---@param args string
---@return string[]
local function split_args(args)
    return vim.split(vim.trim(args), ' ', { trimempty = true })
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
    })

    vim.api.nvim_create_user_command('TerminalManagerOpen', open_terminal_command, {
        nargs = '+',
        desc = 'Reveal an existing terminal: <id> [view]',
    })

    vim.api.nvim_create_user_command('TerminalManagerList', list_terminals_command, {
        nargs = '*',
        desc = 'List registered terminals: [namespace] [cwd_prefix]',
    })

    vim.api.nvim_create_user_command('TerminalManagerHistory', history_command, {
        nargs = 1,
        desc = 'Open captured history for a terminal: <id>',
    })

    registered = true
end

return M

local api = require('terminalia.api')
local command_completion = require('terminalia.commands.completion')
local command_parse = require('terminalia.commands.parse')

local M = {}

local registered = false
local parsed_namespace_filter_from_args = command_parse.parsed_namespace_filter_from_args
local parse_command_args = command_parse.parse_command_args

---@param verb string
---@param terminal terminalia.TerminalRecord
local function notify_terminal(verb, terminal)
    vim.notify(string.format('%s %s (%s)', verb, terminal.id, terminal.name))
end

---Register the plugin's user commands once.
---@param terminalia terminalia.RootModule
function M.ensure(terminalia)
    if registered then
        return
    end

    local function new_terminal_command(command_opts)
        local args = parse_command_args(command_opts)

        local terminal = api.create_and_open({
            name = args[1],
            namespace = args[2],
            view = args[3],
        })

        notify_terminal('Opened', terminal)
    end

    local function open_terminal_command(command_opts)
        local args = parse_command_args(command_opts)

        if #args == 0 then
            error('TerminaliaOpen requires a terminal id')
        end

        local terminal = api.open(args[1], {
            view = args[2],
        })

        notify_terminal('Revealed', terminal)
    end

    local function list_terminals_command(command_opts)
        local args = parse_command_args(command_opts)
        local namespace, namespace_argc = parsed_namespace_filter_from_args(args)
        local lines = api.list_lines({
            namespace = namespace,
            cwd_prefix = args[namespace_argc + 1],
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
        local args = parse_command_args(command_opts)

        if #args == 0 then
            error('TerminaliaHistory requires a terminal id')
        end

        api.open_history(args[1])
    end

    local function open_uri_command(command_opts)
        local args = parse_command_args(command_opts)

        if #args == 0 then
            error('TerminaliaOpenUri requires a Terminalia URI')
        end

        api.open_uri(args[1], {
            view = args[2],
        })
    end

    vim.api.nvim_create_user_command('TerminaliaNew', new_terminal_command, {
        nargs = '*',
        desc = 'Create and reveal a terminal: [name] [namespace] [view]',
        complete = function(arglead, cmdline)
            local argc = command_parse.completion_arg_count(cmdline)

            if argc == 2 then
                return command_completion.namespace_completions(arglead, api)
            end

            if argc == 3 then
                return command_completion.view_completions(arglead)
            end

            return {}
        end,
    })

    vim.api.nvim_create_user_command('TerminaliaOpen', open_terminal_command, {
        nargs = '+',
        desc = 'Reveal an existing terminal: <id> [view]',
        complete = function(arglead, cmdline)
            local argc = command_parse.completion_arg_count(cmdline)

            if argc == 1 then
                return command_completion.terminal_id_completions(arglead, api)
            end

            if argc == 2 then
                return command_completion.view_completions(arglead)
            end

            return {}
        end,
    })

    vim.api.nvim_create_user_command('TerminaliaList', list_terminals_command, {
        nargs = '*',
        desc = 'List registered terminals: [namespace] [cwd_prefix]',
        complete = function(arglead, cmdline)
            local argc = command_parse.list_completion_arg_count(cmdline)

            if argc == 1 then
                return command_completion.namespace_completions(arglead, api)
            end

            if argc == 2 then
                return command_completion.list_cwd_prefix_completions(arglead, cmdline, api)
            end

            return {}
        end,
    })

    vim.api.nvim_create_user_command('TerminaliaHistory', history_command, {
        nargs = 1,
        desc = 'Open transcript history for a terminal: <id>',
        complete = function(arglead)
            return command_completion.terminal_id_completions(arglead, api)
        end,
    })

    vim.api.nvim_create_user_command('TerminaliaOpenUri', open_uri_command, {
        nargs = '+',
        desc = 'Open a Terminalia URI: <uri> [view]',
        complete = function(arglead, cmdline)
            local argc = command_parse.completion_arg_count(cmdline)

            if argc == 2 then
                return command_completion.view_completions(arglead)
            end

            return {}
        end,
    })

    vim.api.nvim_create_user_command('TerminaliaOverseerCurrent', function()
        local context = api.overseer_context()
        local explicit = terminalia.config.overseer_context_id
        local mode = explicit ~= nil and explicit ~= '' and 'explicit' or 'current'

        vim.notify(string.format('Overseer context (%s): %s  [%s]', mode, context.id, context.label))
    end, {
        nargs = 0,
        desc = 'Show the effective Overseer terminal context',
    })

    vim.api.nvim_create_user_command('TerminaliaOverseerUse', function(command_opts)
        local args = parse_command_args(command_opts)
        local context = api.set_overseer_context(args[1])

        vim.notify(string.format('Overseer context: %s  [%s]', context.id, context.label))
    end, {
        nargs = 1,
        desc = 'Set an explicit Overseer terminal context: <context_id>',
        complete = function(arglead)
            return command_completion.context_id_completions(arglead, api)
        end,
    })

    vim.api.nvim_create_user_command('TerminaliaOverseerClear', function()
        local context = api.clear_overseer_context()

        vim.notify(string.format('Overseer context reset to current: %s  [%s]', context.id, context.label))
    end, {
        nargs = 0,
        desc = 'Clear the explicit Overseer terminal context override',
    })

    registered = true
end

return M

local M = {}

local registered = false
local view_kinds = { 'split', 'float' }

---@param cmdline string
---@return table?
local function parsed_cmdline(cmdline)
    local ok, parsed = pcall(vim.api.nvim_parse_cmd, cmdline, {})
    if ok then
        return parsed
    end
end

---@param cmdline string
---@return string[]
local function parse_cmdline_args(cmdline)
    local parsed = parsed_cmdline(cmdline)
    if parsed and parsed.args then
        return parsed.args
    end

    local stripped = cmdline:gsub('^:?%S+%s*', '', 1)
    if stripped == '' then
        return {}
    end

    return vim.split(vim.trim(stripped), ' ', { trimempty = true })
end

---@param command_opts table
---@return string[]
local function parse_command_args(command_opts)
    if command_opts.args == nil or command_opts.args == '' then
        return {}
    end

    if command_opts.fargs and #command_opts.fargs > 0 then
        local has_quotes = false
        for _, arg in ipairs(command_opts.fargs) do
            if arg:find('"', 1, true) then
                has_quotes = true
                break
            end
        end

        if not has_quotes then
            return command_opts.fargs
        end
    end

    local args = {}
    local input = command_opts.args
    local index = 1

    while index <= #input do
        while index <= #input and input:sub(index, index):match('%s') do
            index = index + 1
        end

        if index > #input then
            break
        end

        if input:sub(index, index) == '"' then
            index = index + 1
            local parts = {}

            while index <= #input do
                local char = input:sub(index, index)

                if char == '\\' then
                    local run_start = index

                    while index <= #input and input:sub(index, index) == '\\' do
                        index = index + 1
                    end

                    local backslash_run = index - run_start
                    local next_char = input:sub(index, index)

                    if next_char == '"' then
                        if backslash_run % 2 == 1 then
                            table.insert(parts, string.rep('\\', math.floor(backslash_run / 2)))
                            table.insert(parts, '"')
                            index = index + 1
                        elseif index == #input then
                            table.insert(parts, string.rep('\\', backslash_run))
                            index = index + 1
                            break
                        else
                            table.insert(parts, string.rep('\\', backslash_run / 2))
                            index = index + 1
                            break
                        end
                    else
                        table.insert(parts, string.rep('\\', backslash_run))
                    end
                elseif char == '"' then
                    index = index + 1
                    break
                else
                    table.insert(parts, char)
                    index = index + 1
                end
            end

            table.insert(args, table.concat(parts))
        else
            local next_space = input:find('%s', index)
            if next_space == nil then
                table.insert(args, input:sub(index))
                break
            end

            table.insert(args, input:sub(index, next_space - 1))
            index = next_space + 1
        end
    end

    return args
end

---@param cmdline string
---@return boolean
local function has_trailing_whitespace(cmdline)
    return cmdline:sub(-1):match('%s') ~= nil
end

---@param cmdline string
---@return integer
local function completion_arg_count(cmdline)
    local args = parse_cmdline_args(cmdline)

    if has_trailing_whitespace(cmdline) then
        return #args + 1
    end

    return #args
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

---@param args string[]
---@return string?, integer
local function parsed_namespace_filter_from_args(args)
    local namespace = args[1]
    if namespace == nil or namespace == '' then
        return nil, 0
    end

    local quoted = namespace:match('^"(.*)"$')
    if quoted ~= nil then
        return quoted, 1
    end

    if namespace:sub(1, 1) == '"' then
        local parts = { namespace }

        for index = 2, #args do
            table.insert(parts, args[index])

            local combined = table.concat(parts, ' '):match('^"(.*)"$')
            if combined ~= nil then
                return combined, index
            end
        end
    end

    return namespace, 1
end

---@param arglead string
---@param cmdline string
---@param api table
---@return string[]
local function list_cwd_prefix_completions(arglead, cmdline, api)
    local prefixes = {}
    local namespace = parsed_namespace_filter_from_args(parse_cmdline_args(cmdline))

    for _, terminal in ipairs(api.list({ namespace = namespace })) do
        table.insert(prefixes, terminal.cwd)
    end

    return matching_values(arglead, prefixes)
end

---@param arglead string
---@return string[]
local function view_completions(arglead)
    return matching_values(arglead, view_kinds)
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
        local args = parse_command_args(command_opts)

        local terminal = terminal_manager.api.create_and_open({
            name = args[1],
            namespace = args[2],
            view = args[3],
        })

        notify_terminal('Opened', terminal)
    end

    local function open_terminal_command(command_opts)
        local args = parse_command_args(command_opts)

        if #args == 0 then
            error('TerminalManagerOpen requires a terminal id')
        end

        local terminal = terminal_manager.api.open(args[1], {
            view = args[2],
        })

        notify_terminal('Revealed', terminal)
    end

    local function list_terminals_command(command_opts)
        local args = parse_command_args(command_opts)
        local namespace, namespace_argc = parsed_namespace_filter_from_args(args)
        local lines = terminal_manager.api.list_lines({
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
            error('TerminalManagerHistory requires a terminal id')
        end

        terminal_manager.api.open_history(args[1])
    end

    vim.api.nvim_create_user_command('TerminalManagerNew', new_terminal_command, {
        nargs = '*',
        desc = 'Create and reveal a terminal: [name] [namespace] [view]',
        complete = function(arglead, cmdline)
            local argc = completion_arg_count(cmdline)

            if argc == 2 then
                return namespace_completions(arglead, terminal_manager.api)
            end

            if argc == 3 then
                return view_completions(arglead)
            end

            return {}
        end,
    })

    vim.api.nvim_create_user_command('TerminalManagerOpen', open_terminal_command, {
        nargs = '+',
        desc = 'Reveal an existing terminal: <id> [view]',
        complete = function(arglead, cmdline)
            local argc = completion_arg_count(cmdline)

            if argc == 1 then
                return terminal_id_completions(arglead, terminal_manager.api)
            end

            if argc == 2 then
                return view_completions(arglead)
            end

            return {}
        end,
    })

    vim.api.nvim_create_user_command('TerminalManagerList', list_terminals_command, {
        nargs = '*',
        desc = 'List registered terminals: [namespace] [cwd_prefix]',
        complete = function(arglead, cmdline)
            local argc = completion_arg_count(cmdline)

            if argc == 1 then
                return namespace_completions(arglead, terminal_manager.api)
            end

            if argc == 2 then
                return list_cwd_prefix_completions(arglead, cmdline, terminal_manager.api)
            end

            return {}
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

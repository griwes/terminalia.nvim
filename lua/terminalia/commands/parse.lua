local M = {}

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
function M.parse_cmdline_args(cmdline)
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
function M.parse_command_args(command_opts)
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
function M.has_trailing_whitespace(cmdline)
    return cmdline:sub(-1):match('%s') ~= nil
end

---@param args string[]
---@return string?, integer
function M.parsed_namespace_filter_from_args(args)
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

---@param cmdline string
---@return integer
function M.completion_arg_count(cmdline)
    local args = M.parse_cmdline_args(cmdline)

    if M.has_trailing_whitespace(cmdline) then
        return #args + 1
    end

    return #args
end

---@param cmdline string
---@return integer
function M.list_completion_arg_count(cmdline)
    local args = M.parse_cmdline_args(cmdline)
    local _, namespace_argc = M.parsed_namespace_filter_from_args(args)
    local argc = #args

    if namespace_argc > 1 then
        argc = argc - namespace_argc + 1
    end

    if M.has_trailing_whitespace(cmdline) then
        return argc + 1
    end

    return argc
end

return M

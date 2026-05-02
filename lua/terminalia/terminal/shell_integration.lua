local M = {}

---@class terminalia.ShellIntegrationOptions
---@field commands? string[]
---@field enabled? boolean
---@field open_policy? terminalia.ExternalOpenPolicy
---@field include_cwd? boolean

---@class terminalia.PreparedShellLaunch
---@field command string|string[]
---@field env? table<string, string>
---@field cleanup_paths? string[]

local shell_command_flags = {
    ['-c'] = true,
    ['-ic'] = true,
    ['-lc'] = true,
}

---@param value string
---@return string
local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

---@param command string
---@return boolean
local function is_valid_function_name(command)
    return command:match('^[A-Za-z_][A-Za-z0-9_]*$') ~= nil
end

---@param commands any
---@return string[]
local function normalize_commands(commands)
    if type(commands) ~= 'table' then
        return { 'nvim', 'vim', 'vi' }
    end

    local normalized = {}
    local seen = {}

    for _, command in ipairs(commands) do
        if type(command) == 'string' and is_valid_function_name(command) and not seen[command] then
            table.insert(normalized, command)
            seen[command] = true
        end
    end

    if #normalized == 0 then
        return { 'nvim', 'vim', 'vi' }
    end

    return normalized
end

---@param env table<string, string>?
---@return table<string, string>?
local function nil_if_empty_env(env)
    if type(env) ~= 'table' or next(env) == nil then
        return nil
    end

    return env
end

---@param command string|string[]
---@return string?
local function shell_executable(command)
    if type(command) == 'string' then
        return vim.fs.basename(command)
    end

    if type(command) ~= 'table' or type(command[1]) ~= 'string' then
        return nil
    end

    return vim.fs.basename(command[1])
end

---@param command string|string[]
---@return boolean
function M.supports_shell(command)
    local executable = shell_executable(command)
    return executable == 'sh' or executable == 'bash' or executable == 'zsh'
end

---@param opts? terminalia.ShellIntegrationOptions
---@return string[]
local function open_action_lines(opts)
    opts = opts or {}
    local emit_parts = {
        [[__terminalia_emit_open() { __terminalia_json='{"argv":['; __terminalia_first=1]],
        [[for __terminalia_arg in "$@"; do if [ "$__terminalia_first" = 1 ]; then __terminalia_first=0; else __terminalia_json="$__terminalia_json,"; fi]],
        [[__terminalia_escaped=$(__terminalia_json_escape "$__terminalia_arg")]],
        [[__terminalia_json="$__terminalia_json\"$__terminalia_escaped\""]],
        [[done]],
    }

    if opts.include_cwd == false then
        table.insert(emit_parts, [[__terminalia_json="$__terminalia_json]"]])
    else
        table.insert(emit_parts, [[__terminalia_cwd=$(__terminalia_json_escape "$PWD")]])
        table.insert(emit_parts, [[__terminalia_json="$__terminalia_json],\"cwd\":\"$__terminalia_cwd\""]])
    end

    if type(opts.open_policy) == 'string' and opts.open_policy ~= '' then
        local escaped_policy = opts.open_policy:gsub('\\', '\\\\'):gsub('"', '\\"')
        table.insert(
            emit_parts,
            string.format([[__terminalia_json="$__terminalia_json,\"open_policy\":\"%s\""]], escaped_policy)
        )
    end

    table.insert(emit_parts, [[__terminalia_json="$__terminalia_json}"]])
    table.insert(emit_parts, [[printf '\033]777;terminalia;open;%s\007' "$__terminalia_json"]])
    table.insert(emit_parts, '}')

    return {
        [[__terminalia_json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }]],
        table.concat(emit_parts, '; '),
    }
end

---@param opts? terminalia.ShellIntegrationOptions
---@return string
local function editor_env_command(opts)
    local lines = open_action_lines(opts)
    table.insert(lines, [[__terminalia_emit_open "$@"]])

    return string.format('sh -c %s terminalia-editor', shell_quote(table.concat(lines, '; ')))
end

---@param opts? terminalia.ShellIntegrationOptions
---@return string
function M.open_action_prelude(opts)
    opts = opts or {}
    local lines = open_action_lines(opts)

    local commands = normalize_commands(opts.commands)

    for _, command in ipairs(commands) do
        table.insert(lines, string.format('unalias %s 2>/dev/null || true', command))
        table.insert(lines, string.format('%s() { __terminalia_emit_open "$@"; }', command))
    end

    local editor_command = shell_quote(editor_env_command(opts))
    table.insert(lines, string.format('export EDITOR=%s', editor_command))
    table.insert(lines, string.format('export VISUAL=%s', editor_command))

    return table.concat(lines, '; ')
end

---@param command string|string[]
---@return integer?
local function shell_script_arg_index(command)
    if type(command) ~= 'table' then
        return nil
    end

    for index = 2, #command do
        if shell_command_flags[command[index]] then
            return index + 1
        end
    end

    return nil
end

---@param command string|string[]
---@return boolean
local function is_bare_interactive_shell(command)
    if type(command) == 'string' then
        return M.supports_shell(command)
    end

    return type(command) == 'table' and #command == 1 and M.supports_shell(command)
end

---@return string
local function create_startup_dir()
    local dir, err = vim.uv.fs_mkdtemp(string.format('%s/terminalia-shell.XXXXXX', vim.fn.stdpath('run')))

    if dir == nil then
        error(string.format('Failed to create Terminalia shell startup directory: %s', err))
    end

    return dir
end

---@param path string
---@param lines string[]
local function write_startup_file(path, lines)
    local ok, err = pcall(vim.fn.writefile, lines, path)

    if not ok then
        error(string.format('Failed to write Terminalia shell startup file %s: %s', path, err))
    end
end

---@param shell string
---@param prelude string
---@param env table<string, string>
---@return terminalia.PreparedShellLaunch
local function sh_startup_launch(shell, prelude, env)
    local dir = create_startup_dir()
    local startup_file = vim.fs.joinpath(dir, 'env')
    env.TERMINALIA_ORIGINAL_ENV = env.ENV or vim.env.ENV
    env.ENV = startup_file

    write_startup_file(startup_file, {
        [[if [ -n "${TERMINALIA_ORIGINAL_ENV:-}" ] && [ -r "$TERMINALIA_ORIGINAL_ENV" ]; then . "$TERMINALIA_ORIGINAL_ENV"; fi]],
        prelude,
        [[unset TERMINALIA_ORIGINAL_ENV]],
    })

    return {
        command = { shell },
        env = nil_if_empty_env(env),
        cleanup_paths = { dir },
    }
end

---@param shell string
---@param prelude string
---@param env table<string, string>
---@return terminalia.PreparedShellLaunch
local function bash_startup_launch(shell, prelude, env)
    local dir = create_startup_dir()
    local startup_file = vim.fs.joinpath(dir, 'bashrc')

    write_startup_file(startup_file, {
        [[if [ -r "${HOME:-}/.bashrc" ]; then . "${HOME:-}/.bashrc"; fi]],
        prelude,
    })

    return {
        command = { shell, '--rcfile', startup_file, '-i' },
        env = nil_if_empty_env(env),
        cleanup_paths = { dir },
    }
end

---@param shell string
---@param prelude string
---@param env table<string, string>
---@return terminalia.PreparedShellLaunch
local function zsh_startup_launch(shell, prelude, env)
    local dir = create_startup_dir()
    local original_zdotdir = env.ZDOTDIR or vim.env.ZDOTDIR

    env.TERMINALIA_BOOTSTRAP_ZDOTDIR = dir
    env.TERMINALIA_ORIGINAL_ZDOTDIR = original_zdotdir
    env.ZDOTDIR = dir

    write_startup_file(vim.fs.joinpath(dir, '.zshenv'), {
        [[__terminalia_user_zdotdir="${TERMINALIA_ORIGINAL_ZDOTDIR:-${HOME:-}}"]],
        [[if [ -n "$__terminalia_user_zdotdir" ] && [ -r "$__terminalia_user_zdotdir/.zshenv" ]; then . "$__terminalia_user_zdotdir/.zshenv"; fi]],
        [[if [ "${ZDOTDIR:-}" = "$TERMINALIA_BOOTSTRAP_ZDOTDIR" ]; then ZDOTDIR="$__terminalia_user_zdotdir"; fi]],
        [[TERMINALIA_USER_ZDOTDIR="${ZDOTDIR:-$__terminalia_user_zdotdir}"]],
        [[export TERMINALIA_USER_ZDOTDIR]],
        [[ZDOTDIR="$TERMINALIA_BOOTSTRAP_ZDOTDIR"]],
        [[export ZDOTDIR]],
        [[unset __terminalia_user_zdotdir]],
    })
    write_startup_file(vim.fs.joinpath(dir, '.zshrc'), {
        [[if [ -n "${TERMINALIA_USER_ZDOTDIR:-}" ]; then ZDOTDIR="$TERMINALIA_USER_ZDOTDIR"; fi]],
        [[if [ -n "${ZDOTDIR:-}" ] && [ -r "$ZDOTDIR/.zshrc" ]; then . "$ZDOTDIR/.zshrc"; fi]],
        prelude,
        [[unset TERMINALIA_BOOTSTRAP_ZDOTDIR TERMINALIA_ORIGINAL_ZDOTDIR TERMINALIA_USER_ZDOTDIR]],
    })

    return {
        command = { shell, '-i' },
        env = nil_if_empty_env(env),
        cleanup_paths = { dir },
    }
end

---@param command string|string[]
---@param prelude string
---@param env table<string, string>
---@return terminalia.PreparedShellLaunch
local function interactive_shell_launch(command, prelude, env)
    local shell = type(command) == 'table' and command[1] or command
    local executable = assert(shell_executable(shell), 'Terminalia shell executable missing')

    if executable == 'bash' then
        return bash_startup_launch(shell, prelude, env)
    end

    if executable == 'zsh' then
        return zsh_startup_launch(shell, prelude, env)
    end

    return sh_startup_launch(shell, prelude, env)
end

---@param command string|string[]
---@param opts? terminalia.ShellIntegrationOptions|{ env?: table<string, string> }
---@return terminalia.PreparedShellLaunch
function M.prepare_launch(command, opts)
    opts = opts or {}

    if opts.enabled == false or not M.supports_shell(command) then
        return {
            command = command,
            env = nil_if_empty_env(opts.env),
        }
    end

    local env = vim.deepcopy(opts.env or {})
    local prelude = M.open_action_prelude({
        commands = opts.commands,
        include_cwd = opts.include_cwd,
        open_policy = opts.open_policy,
    })

    if type(command) == 'table' then
        local script_index = shell_script_arg_index(command)

        if script_index ~= nil then
            local wrapped = vim.deepcopy(command)
            wrapped[script_index] = prelude .. '; ' .. (wrapped[script_index] or '')
            return {
                command = wrapped,
                env = nil_if_empty_env(env),
            }
        end

        if is_bare_interactive_shell(command) then
            return interactive_shell_launch(command, prelude, env)
        end

        return {
            command = command,
            env = nil_if_empty_env(env),
        }
    end

    if is_bare_interactive_shell(command) then
        return interactive_shell_launch(command, prelude, env)
    end

    return {
        command = command,
        env = nil_if_empty_env(env),
    }
end

return M

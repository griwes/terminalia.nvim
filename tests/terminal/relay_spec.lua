describe('terminalia external open handling', function()
    local history_dir
    local state_file
    local workspace

    local function mkdtemp(prefix)
        local dir, err = vim.uv.fs_mkdtemp(vim.fs.joinpath(vim.fn.stdpath('run'), prefix .. '.XXXXXX'))

        assert(dir, err)

        return dir
    end

    before_each(function()
        local plugin = require('terminalia')
        history_dir = vim.fn.tempname()
        state_file = vim.fn.tempname()
        workspace = mkdtemp('terminalia-relay')

        plugin.setup({
            external_open_policy = 'tab',
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = state_file,
        })
        plugin.api.clear()
        vim.cmd('silent! %bwipeout!')
        vim.cmd('enew')
    end)

    it('plans file, position, command, stdin, and passthrough arguments', function()
        local plugin = require('terminalia')
        local plan = plugin.api.plan_external_open({
            '--clean',
            '--cmd',
            'set hidden',
            '-d',
            '+12:4',
            'src/init.lua',
            '+set number',
            '--',
            '-literal',
            '-',
        }, {
            cwd = workspace,
            open_policy = 'split',
        })

        assert.are.equal(workspace, plan.cwd)
        assert.are.equal('split', plan.open_policy)
        assert.is_true(plan.diff)
        assert.are.same({ '--clean' }, plan.passthrough_args)
        assert.are.same({ 'set hidden' }, plan.pre_commands)
        assert.are.same({ 'set number' }, plan.commands)
        assert.are.equal(3, #plan.targets)
        assert.are.equal(vim.fs.joinpath(workspace, 'src/init.lua'), plan.targets[1].path)
        assert.are.equal(12, plan.targets[1].line)
        assert.are.equal(4, plan.targets[1].col)
        assert.are.equal(vim.fs.joinpath(workspace, '-literal'), plan.targets[2].path)
        assert.is_true(plan.targets[3].stdin)
    end)

    it('parses file:line and file:line:col targets', function()
        local plugin = require('terminalia')
        local plan = plugin.api.plan_external_open({
            'alpha.lua:9',
            'beta.lua:10:3',
        }, {
            cwd = workspace,
        })

        assert.are.equal(vim.fs.joinpath(workspace, 'alpha.lua'), plan.targets[1].path)
        assert.are.equal(9, plan.targets[1].line)
        assert.is_nil(plan.targets[1].col)
        assert.are.equal(vim.fs.joinpath(workspace, 'beta.lua'), plan.targets[2].path)
        assert.are.equal(10, plan.targets[2].line)
        assert.are.equal(3, plan.targets[2].col)
    end)

    it('classifies directory targets in external open plans', function()
        local plugin = require('terminalia')
        local directory = vim.fs.joinpath(workspace, 'project-dir')
        vim.fn.mkdir(directory, 'p')

        local plan = plugin.api.plan_external_open({
            'project-dir',
        }, {
            cwd = workspace,
        })

        assert.are.equal(directory, plan.targets[1].path)
        assert.is_true(plan.targets[1].is_directory)
    end)

    it('opens external files in tabs by default and applies cursor positions', function()
        local plugin = require('terminalia')
        local path = vim.fs.joinpath(workspace, 'target.lua')
        vim.fn.writefile({ 'one', 'two', 'three' }, path)

        local original_tabs = #vim.api.nvim_list_tabpages()
        plugin.api.open_external({ 'target.lua:2:2' }, {
            cwd = workspace,
        })

        assert.are.equal(original_tabs + 1, #vim.api.nvim_list_tabpages())
        assert.are.equal(path, vim.api.nvim_buf_get_name(0))
        assert.are.same({ 2, 1 }, vim.api.nvim_win_get_cursor(0))
    end)

    it('opens directory targets through the external open path', function()
        local plugin = require('terminalia')
        local directory = vim.fs.joinpath(workspace, 'project-dir')
        vim.fn.mkdir(directory, 'p')

        local original_tabs = #vim.api.nvim_list_tabpages()
        plugin.api.open_external({ 'project-dir' }, {
            cwd = workspace,
        })

        assert.are.equal(original_tabs + 1, #vim.api.nvim_list_tabpages())
        assert.are.equal(directory, vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
    end)

    it('applies plus commands after the first external target is open', function()
        local plugin = require('terminalia')
        local path = vim.fs.joinpath(workspace, 'target.lua')
        vim.fn.writefile({ 'one', 'two' }, path)

        plugin.api.open_external({ 'target.lua', '+let b:terminalia_relay_marker = expand("%:t")' }, {
            cwd = workspace,
            open_policy = 'current',
        })

        assert.are.equal(path, vim.api.nvim_buf_get_name(0))
        assert.are.equal('target.lua', vim.b.terminalia_relay_marker)
    end)

    it('opens diff invocations as diff windows', function()
        local plugin = require('terminalia')
        local left = vim.fs.joinpath(workspace, 'left.txt')
        local right = vim.fs.joinpath(workspace, 'right.txt')
        vim.fn.writefile({ 'left' }, left)
        vim.fn.writefile({ 'right' }, right)

        plugin.api.open_external({ '-d', 'left.txt', 'right.txt' }, {
            cwd = workspace,
            open_policy = 'current',
        })

        local wins = vim.api.nvim_tabpage_list_wins(0)
        assert.are.equal(2, #wins)
        for _, winid in ipairs(wins) do
            assert.is_true(vim.api.nvim_get_option_value('diff', { win = winid }))
        end
        assert.are.equal(right, vim.api.nvim_buf_get_name(0))
    end)

    it('reuses an existing file window when requested', function()
        local plugin = require('terminalia')
        local path = vim.fs.joinpath(workspace, 'reuse.lua')
        vim.fn.writefile({ 'reuse me' }, path)

        vim.cmd('edit ' .. vim.fn.fnameescape(path))
        local original_tab = vim.api.nvim_get_current_tabpage()
        local original_win = vim.api.nvim_get_current_win()

        vim.cmd('tabnew')
        plugin.api.open_external({ 'reuse.lua' }, {
            cwd = workspace,
            open_policy = 'reuse',
        })

        assert.are.equal(original_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(original_win, vim.api.nvim_get_current_win())
        assert.are.equal(path, vim.api.nvim_buf_get_name(0))
    end)

    it('forwards quoted arguments through the external open command surface', function()
        local plugin = require('terminalia')
        local path = vim.fs.joinpath(workspace, 'surface.lua')
        vim.fn.writefile({ 'surface' }, path)
        vim.cmd('lcd ' .. vim.fn.fnameescape(workspace))
        vim.g.terminalia_surface_pre = nil

        vim.cmd([[TerminaliaExternalOpen --cmd "let g:terminalia_surface_pre = expand('%:t')" surface.lua]])

        assert.are.equal('', vim.g.terminalia_surface_pre)
        assert.are.equal(path, vim.api.nvim_buf_get_name(0))
        plugin.api.clear()
    end)

    it('opens stdin as a scratch buffer when requested', function()
        local plugin = require('terminalia')

        plugin.api.open_external({ '-' }, {
            cwd = workspace,
            open_policy = 'current',
            stdin_data = { 'from stdin' },
        })

        assert.are.equal('terminalia://external/stdin', vim.api.nvim_buf_get_name(0))
        assert.are.same({ 'from stdin' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
        assert.are.equal('nofile', vim.bo.buftype)
    end)

    it('opens repeated stdin requests without scratch buffer name collisions', function()
        local plugin = require('terminalia')

        plugin.api.open_external({ '-' }, {
            cwd = workspace,
            stdin_data = { 'first' },
        })
        local first = vim.api.nvim_get_current_buf()

        vim.cmd('tabnew')
        plugin.api.open_external({ '-' }, {
            cwd = workspace,
            stdin_data = { 'second' },
        })

        assert.are_not.equal(first, vim.api.nvim_get_current_buf())
        assert.are.equal('terminalia://external/stdin/2', vim.api.nvim_buf_get_name(0))
        assert.are.same({ 'second' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    end)

    it('parses and strips terminal-owned OSC open actions', function()
        local plugin = require('terminalia')
        local sequence = plugin.api.build_terminal_open_action({
            argv = { 'owned.lua:3' },
        })
        local action = plugin.api.parse_terminal_action_sequence(sequence)

        assert.are.same({ argv = { 'owned.lua:3' } }, plugin.api.parse_terminal_action(sequence))
        assert.are.equal('open', action.kind)
        assert.are.same({ argv = { 'owned.lua:3' } }, action.payload)
        assert.are.equal(sequence, action.sequence)
        assert.are.same({ 'beforeafter' }, plugin.api.strip_terminal_action_chunks({ 'before' .. sequence .. 'after' }))
    end)

    it('round-trips provider metadata through the terminal-owned action builder', function()
        local plugin = require('terminalia')
        local sequence = plugin.api.build_terminal_open_action({
            argv = { 'remote.lua:4:2' },
            cwd = '/workspace/project',
            metadata = {
                provider = 'laboratory',
                container = 'dev',
            },
            open_policy = 'current',
        })
        local action = plugin.api.parse_terminal_action_sequence(sequence)

        assert.are.equal('open', action.kind)
        assert.are.same({
            argv = { 'remote.lua:4:2' },
            cwd = '/workspace/project',
            metadata = {
                provider = 'laboratory',
                container = 'dev',
            },
            open_policy = 'current',
        }, action.payload)
    end)

    it('strips split terminal-owned OSC open actions with explicit parser state', function()
        local plugin = require('terminalia')
        local state = plugin.api.new_terminal_action_strip_state()

        local first = plugin.api.strip_terminal_action_chunks({
            'before\027]777;terminalia;open;{"argv":',
        }, state)
        local second = plugin.api.strip_terminal_action_chunks({
            '["owned.lua:3"]}\007after',
        }, state)

        assert.are.same({ 'before' }, first)
        assert.are.same({ 'after' }, second)
    end)

    it('extracts split terminal-owned OSC actions for provider enrichment', function()
        local plugin = require('terminalia')
        local state = plugin.api.new_terminal_action_strip_state()

        local first_chunks, first_actions = plugin.api.extract_terminal_action_chunks({
            'before\027]777;terminalia;open;{"argv":',
        }, state)
        local second_chunks, second_actions = plugin.api.extract_terminal_action_chunks({
            '["owned.lua:3"],"metadata":{"provider":"laboratory"}}\007after',
        }, state)

        assert.are.same({ 'before' }, first_chunks)
        assert.are.same({}, first_actions)
        assert.are.same({ 'after' }, second_chunks)
        assert.are.equal(1, #second_actions)
        assert.are.equal('open', second_actions[1].kind)
        assert.are.same({ 'owned.lua:3' }, second_actions[1].payload.argv)
        assert.are.equal('laboratory', second_actions[1].payload.metadata.provider)
    end)

    it('keeps OSC strip state independent across streams', function()
        local plugin = require('terminalia')
        local stdout_state = plugin.api.new_terminal_action_strip_state()
        local stderr_state = plugin.api.new_terminal_action_strip_state()

        assert.are.same(
            {},
            plugin.api.strip_terminal_action_chunks({
                '\027]777;terminalia;open;{"argv":',
            }, stdout_state)
        )
        assert.are.same(
            { 'stderr-visible' },
            plugin.api.strip_terminal_action_chunks({
                'stderr-visible',
            }, stderr_state)
        )
        assert.are.same(
            {},
            plugin.api.strip_terminal_action_chunks({
                '["owned.lua"]}\007',
            }, stdout_state)
        )
    end)

    it('routes terminal-owned OSC open actions through the external open api', function()
        local plugin = require('terminalia')
        local path = vim.fs.joinpath(workspace, 'owned.lua')
        vim.fn.writefile({ 'one', 'two', 'three' }, path)

        local terminal = plugin.api.create({
            command = {
                'sh',
                '-c',
                [[printf '%b' '\033]777;terminalia;open;{"argv":["owned.lua:3:1"],"open_policy":"current"}\007']],
            },
            cwd = workspace,
            name = 'owned action',
        })
        plugin.api.start(terminal.id)

        vim.wait(1000, function()
            return vim.api.nvim_buf_get_name(0) == path
        end)

        assert.are.equal(path, vim.api.nvim_buf_get_name(0))
        assert.are.same({ 3, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    it('lets context providers rewrite terminal-owned OSC open actions before default handling', function()
        local plugin = require('terminalia')
        local local_path = vim.fs.joinpath(workspace, 'local.lua')
        vim.fn.writefile({ 'one', 'two', 'three' }, local_path)

        plugin.api.register_context_provider('relay_rewrite_fixture', {
            plan_command = function() end,
            transform_terminal_action = function(_, action)
                assert.are.equal('open', action.kind)
                assert.are.same({ '/remote/owned.lua:2:1' }, action.payload.argv)

                local rewritten_sequence = plugin.api.build_terminal_open_action({
                    argv = { 'local.lua:2:1' },
                    cwd = workspace,
                    metadata = vim.tbl_extend('force', action.payload.metadata or {}, {
                        translated = true,
                    }),
                    open_policy = 'current',
                })

                return plugin.api.parse_terminal_action_sequence(rewritten_sequence)
            end,
        })

        local context = plugin.api.create_child_context(plugin.api.host_context().id, {
            kind = 'relay_rewrite_fixture',
            label = 'remote fixture',
        })
        local terminal = plugin.api.create({
            context_id = context.id,
            cwd = '/remote',
            name = 'provider action',
        })

        vim.b.terminalia_id = terminal.id
        vim.api.nvim_exec_autocmds('TermRequest', {
            buffer = 0,
            data = {
                sequence = plugin.api.build_terminal_open_action({
                    argv = { '/remote/owned.lua:2:1' },
                    metadata = {
                        provider = 'relay_rewrite_fixture',
                    },
                    open_policy = 'current',
                }),
            },
        })

        vim.wait(1000, function()
            return vim.api.nvim_buf_get_name(0) == local_path
        end)

        assert.are.equal(local_path, vim.api.nvim_buf_get_name(0))
        assert.are.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    it('lets context providers suppress default terminal-owned OSC open handling', function()
        local plugin = require('terminalia')
        local path = vim.fs.joinpath(workspace, 'suppressed.lua')
        vim.fn.writefile({ 'one' }, path)
        local handled_payload

        plugin.api.register_context_provider('relay_suppress_fixture', {
            plan_command = function() end,
            transform_terminal_action = function(_, action)
                handled_payload = vim.deepcopy(action.payload)
                return false
            end,
        })

        local context = plugin.api.create_child_context(plugin.api.host_context().id, {
            kind = 'relay_suppress_fixture',
            label = 'suppress fixture',
        })
        local terminal = plugin.api.create({
            context_id = context.id,
            cwd = workspace,
            name = 'suppressed action',
        })

        vim.b.terminalia_id = terminal.id
        vim.api.nvim_exec_autocmds('TermRequest', {
            buffer = 0,
            data = {
                sequence = plugin.api.build_terminal_open_action({
                    argv = { 'suppressed.lua' },
                    open_policy = 'current',
                }),
            },
        })

        vim.wait(100)

        assert.are.same({
            argv = { 'suppressed.lua' },
            open_policy = 'current',
        }, handled_payload)
        assert.are_not.equal(path, vim.api.nvim_buf_get_name(0))
    end)

    it('reports context provider terminal-owned OSC transform failures without opening targets', function()
        local plugin = require('terminalia')
        local path = vim.fs.joinpath(workspace, 'failed.lua')
        vim.fn.writefile({ 'one' }, path)
        local notifications = {}
        local original_notify = vim.notify

        plugin.api.register_context_provider('relay_error_fixture', {
            plan_command = function() end,
            transform_terminal_action = function()
                error('provider transform failed')
            end,
        })

        local context = plugin.api.create_child_context(plugin.api.host_context().id, {
            kind = 'relay_error_fixture',
            label = 'error fixture',
        })
        local terminal = plugin.api.create({
            context_id = context.id,
            cwd = workspace,
            name = 'error action',
        })

        vim.b.terminalia_id = terminal.id
        vim.notify = function(message)
            table.insert(notifications, message)
        end

        vim.api.nvim_exec_autocmds('TermRequest', {
            buffer = 0,
            data = {
                sequence = plugin.api.build_terminal_open_action({
                    argv = { 'failed.lua' },
                    open_policy = 'current',
                }),
            },
        })

        vim.notify = original_notify

        assert.are_not.equal(path, vim.api.nvim_buf_get_name(0))
        assert.are.equal(1, #notifications)
        assert.truthy(notifications[1]:find('provider transform failed', 1, true))
    end)

    it('rejects terminal-owned OSC open actions that execute editor commands', function()
        local plugin = require('terminalia')
        local path = vim.fs.joinpath(workspace, 'owned.lua')
        vim.fn.writefile({ 'one' }, path)

        local terminal = plugin.api.create({
            cwd = workspace,
            name = 'owned action',
        })
        vim.b.terminalia_id = terminal.id
        vim.g.terminalia_owned_action_command = nil
        local notifications = {}
        local original_notify = vim.notify
        vim.notify = function(message)
            table.insert(notifications, message)
        end

        vim.api.nvim_exec_autocmds('TermRequest', {
            buffer = 0,
            data = {
                sequence = '\027]777;terminalia;open;{"argv":["--cmd","let g:terminalia_owned_action_command = 1","owned.lua"],"open_policy":"current"}\007',
            },
        })

        vim.wait(100)
        vim.notify = original_notify

        assert.is_nil(vim.g.terminalia_owned_action_command)
        assert.are_not.equal(path, vim.api.nvim_buf_get_name(0))
        assert.are.equal(1, #notifications)
    end)

    it('clears pending OSC strip state when terminal ids are reused', function()
        local plugin = require('terminalia')
        plugin.setup({
            persist_history = false,
        })
        local first = plugin.api.create({
            command = { 'sh', '-c', [[printf '%b' '\033]777;terminalia;open;{"argv":']] },
            cwd = workspace,
            name = 'partial action',
        })

        plugin.api.start(first.id)
        plugin.api.wait(first.id, 1000)
        plugin.api.clear()

        local second = plugin.api.create({
            command = { 'sh', '-c', [[printf 'visible-output\n']] },
            cwd = workspace,
            name = 'reused id',
        })

        assert.are.equal(first.id, second.id)
        plugin.api.start(second.id)
        plugin.api.wait(second.id, 1000)

        local output = plugin.api.output(second.id).output

        assert.truthy(output:find('visible%-output'))
    end)

    it('prepares interactive shell editor integration without stdin bootstrap or PATH shims', function()
        local shell_integration = require('terminalia.terminal.shell_integration')
        local launch = shell_integration.prepare_launch({ 'sh' }, {
            open_policy = 'current',
        })

        assert.are.same('sh', launch.command[1])
        assert.is_nil(launch.command[2])
        assert.is_nil(launch.bootstrap)
        assert.truthy(launch.env)
        assert.truthy(launch.env.ENV)
        assert.truthy(launch.cleanup_paths)
        assert.is_nil(launch.env.PATH)

        local startup = table.concat(vim.fn.readfile(launch.env.ENV), '\n')

        assert.truthy(startup:find('__terminalia_json_escape', 1, true))
        assert.truthy(startup:find('__terminalia_emit_open', 1, true))
        assert.truthy(startup:find('nvim() { __terminalia_emit_open "$@"; }', 1, true))
        assert.truthy(startup:find('vim() { __terminalia_emit_open "$@"; }', 1, true))
        assert.truthy(startup:find('vi() { __terminalia_emit_open "$@"; }', 1, true))
        assert.truthy(startup:find('export EDITOR=', 1, true))
        assert.truthy(startup:find('export VISUAL=', 1, true))
        assert.truthy(startup:find('terminalia-editor', 1, true))
        assert.is_nil(startup:find('\027', 1, true))
        assert.is_nil(startup:find('\007', 1, true))
        assert.truthy(startup:find([[\033]777;terminalia;open;]], 1, true))
        assert.truthy(startup:find([[\007]], 1, true))

        for _, path in ipairs(launch.cleanup_paths or {}) do
            vim.fn.delete(path, 'rf')
        end
    end)

    it('opens files from nvim commands typed into an integrated Terminalia shell', function()
        local plugin = require('terminalia')
        local path = vim.fs.joinpath(workspace, 'typed.lua')
        vim.fn.writefile({ 'one', 'two', 'three' }, path)
        plugin.setup({
            external_open_policy = 'current',
            persist_history = false,
        })

        local terminal = plugin.api.create({
            command = { 'sh' },
            cwd = workspace,
            name = 'integrated shell',
        })

        plugin.api.start(terminal.id)
        vim.wait(200)
        local record = assert(plugin.api.get(terminal.id))
        local terminal_screen = table.concat(vim.api.nvim_buf_get_lines(assert(record.bufnr), 0, -1, false), '\n')
        local captured = plugin.api.output(terminal.id).output
        local visible_output = terminal_screen .. '\n' .. captured

        assert.is_nil(visible_output:find('stty %-echo'))
        assert.is_nil(visible_output:find('__terminalia_json_escape', 1, true))
        assert.is_nil(visible_output:find('__terminalia_emit_open', 1, true))

        plugin.api.send(terminal.id, 'nvim typed.lua:2:1\n')

        vim.wait(2000, function()
            return vim.api.nvim_buf_get_name(0) == path
        end)

        plugin.api.kill(terminal.id)

        assert.are.equal(path, vim.api.nvim_buf_get_name(0))
        assert.are.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    it('opens files from default vim-compatible commands typed into an integrated Terminalia shell', function()
        local plugin = require('terminalia')
        local path = vim.fs.joinpath(workspace, 'vim-compatible.lua')
        vim.fn.writefile({ 'one', 'two', 'three' }, path)
        plugin.setup({
            external_open_policy = 'current',
            persist_history = false,
        })

        local terminal = plugin.api.create({
            command = { 'sh' },
            cwd = workspace,
            name = 'integrated vim shell',
        })

        plugin.api.start(terminal.id)
        vim.wait(200)
        plugin.api.send(terminal.id, 'vim vim-compatible.lua:2:1\n')

        vim.wait(2000, function()
            return vim.api.nvim_buf_get_name(0) == path
        end)

        plugin.api.kill(terminal.id)

        assert.are.equal(path, vim.api.nvim_buf_get_name(0))
        assert.are.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    it('opens multiple files from nvim commands typed into an integrated Terminalia shell', function()
        local plugin = require('terminalia')
        local first_path = vim.fs.joinpath(workspace, 'multi-one.lua')
        local second_path = vim.fs.joinpath(workspace, 'multi-two.lua')
        vim.fn.writefile({ 'one', 'two', 'three' }, first_path)
        vim.fn.writefile({ 'alpha', 'beta', 'gamma' }, second_path)
        plugin.setup({
            external_open_policy = 'tab',
            persist_history = false,
        })

        local terminal = plugin.api.create({
            command = { 'sh' },
            cwd = workspace,
            name = 'integrated multi shell',
        })

        plugin.api.start(terminal.id)
        vim.wait(200)
        local original_tab_count = #vim.api.nvim_list_tabpages()
        plugin.api.send(terminal.id, 'nvim multi-one.lua:2:1 multi-two.lua:3:1\n')

        assert.is_true(vim.wait(2000, function()
            return vim.api.nvim_buf_get_name(0) == second_path
        end))

        plugin.api.kill(terminal.id)

        local open_paths = {}
        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
            for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
                open_paths[vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(winid))] = true
            end
        end

        assert.are.equal(original_tab_count + 2, #vim.api.nvim_list_tabpages())
        assert.is_true(open_paths[first_path])
        assert.is_true(open_paths[second_path])
        assert.are.same({ 3, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    it('opens files from EDITOR in a child process of an integrated Terminalia shell', function()
        local plugin = require('terminalia')
        local path = vim.fs.joinpath(workspace, 'editor.lua')
        vim.fn.writefile({ 'one', 'two', 'three' }, path)
        plugin.setup({
            external_open_policy = 'current',
            persist_history = false,
        })

        local terminal = plugin.api.create({
            command = { 'sh' },
            cwd = workspace,
            name = 'editor shell',
        })

        plugin.api.start(terminal.id)
        vim.wait(200)
        plugin.api.send(terminal.id, [[sh -c "$EDITOR \"\$@\"" terminalia-tool editor.lua:3:1]] .. '\n')

        vim.wait(2000, function()
            return vim.api.nvim_buf_get_name(0) == path
        end)

        plugin.api.kill(terminal.id)

        assert.are.equal(path, vim.api.nvim_buf_get_name(0))
        assert.are.same({ 3, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    it('opens files from VISUAL in a child process of an integrated Terminalia shell', function()
        local plugin = require('terminalia')
        local path = vim.fs.joinpath(workspace, 'visual.lua')
        vim.fn.writefile({ 'one', 'two', 'three' }, path)
        plugin.setup({
            external_open_policy = 'current',
            persist_history = false,
        })

        local terminal = plugin.api.create({
            command = { 'sh' },
            cwd = workspace,
            name = 'visual shell',
        })

        plugin.api.start(terminal.id)
        vim.wait(200)
        plugin.api.send(terminal.id, [[sh -c "$VISUAL \"\$@\"" terminalia-tool visual.lua:3:1]] .. '\n')

        vim.wait(2000, function()
            return vim.api.nvim_buf_get_name(0) == path
        end)

        plugin.api.kill(terminal.id)

        assert.are.equal(path, vim.api.nvim_buf_get_name(0))
        assert.are.same({ 3, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    it('keeps bootstrap code out of default-shell terminal buffers', function()
        local plugin = require('terminalia')
        plugin.setup({
            shell = 'sh',
            persist_history = false,
        })

        local terminal = plugin.api.create({
            cwd = workspace,
            name = 'default integrated shell',
        })

        plugin.api.start(terminal.id)
        vim.wait(200)

        local record = assert(plugin.api.get(terminal.id))
        local terminal_screen = table.concat(vim.api.nvim_buf_get_lines(assert(record.bufnr), 0, -1, false), '\n')
        local captured = plugin.api.output(terminal.id).output
        local visible_output = terminal_screen .. '\n' .. captured

        plugin.api.kill(terminal.id)

        assert.is_nil(visible_output:find('stty %-echo'))
        assert.is_nil(visible_output:find('__terminalia_json_escape', 1, true))
        assert.is_nil(visible_output:find('__terminalia_emit_open', 1, true))
        assert.is_nil(visible_output:find('__TERMINALIA_CWD__', 1, true))
    end)

    it('preserves zsh startup output while hiding bootstrap code', function()
        if vim.fn.executable('zsh') == 0 then
            pending('zsh is not available')
            return
        end

        local zdotdir = assert(vim.uv.fs_mkdtemp(vim.fs.joinpath(workspace, 'zdotdir.XXXXXX')))
        vim.fn.writefile({ [[print -r -- TERMINALIA_STARTUP_SURVIVES]] }, vim.fs.joinpath(zdotdir, '.zshrc'))

        local plugin = require('terminalia')
        plugin.setup({
            shell = 'zsh',
            persist_history = false,
        })

        local terminal = plugin.api.create({
            cwd = workspace,
            env = {
                ZDOTDIR = zdotdir,
            },
            name = 'zsh startup shell',
        })

        plugin.api.start(terminal.id)
        vim.wait(2000, function()
            local record = assert(plugin.api.get(terminal.id))
            local terminal_screen = table.concat(vim.api.nvim_buf_get_lines(assert(record.bufnr), 0, -1, false), '\n')
            local captured = plugin.api.output(terminal.id).output

            return (terminal_screen .. '\n' .. captured):find('TERMINALIA_STARTUP_SURVIVES', 1, true) ~= nil
        end)

        local record = assert(plugin.api.get(terminal.id))
        local terminal_screen = table.concat(vim.api.nvim_buf_get_lines(assert(record.bufnr), 0, -1, false), '\n')
        local captured = plugin.api.output(terminal.id).output
        local visible_output = terminal_screen .. '\n' .. captured

        plugin.api.kill(terminal.id)

        assert.truthy(visible_output:find('TERMINALIA_STARTUP_SURVIVES', 1, true), visible_output)
        assert.is_nil(visible_output:find('stty %-echo'))
        assert.is_nil(visible_output:find('__terminalia_json_escape', 1, true))
        assert.is_nil(visible_output:find('__terminalia_emit_open', 1, true))
        assert.is_nil(visible_output:find('__TERMINALIA_CWD__', 1, true))
    end)

    it('keeps bootstrap code out of zsh terminal buffers when zsh is available', function()
        if vim.fn.executable('zsh') == 0 then
            pending('zsh is not available')
            return
        end

        local plugin = require('terminalia')
        plugin.setup({
            shell = 'zsh',
            persist_history = false,
        })

        local terminal = plugin.api.create({
            cwd = workspace,
            name = 'zsh integrated shell',
        })

        plugin.api.start(terminal.id)
        vim.wait(500)

        local record = assert(plugin.api.get(terminal.id))
        local terminal_screen = table.concat(vim.api.nvim_buf_get_lines(assert(record.bufnr), 0, -1, false), '\n')
        local captured = plugin.api.output(terminal.id).output
        local visible_output = terminal_screen .. '\n' .. captured

        plugin.api.kill(terminal.id)

        assert.is_nil(visible_output:find('stty %-echo'))
        assert.is_nil(visible_output:find('__terminalia_json_escape', 1, true))
        assert.is_nil(visible_output:find('__terminalia_emit_open', 1, true))
        assert.is_nil(visible_output:find('__TERMINALIA_CWD__', 1, true))
    end)
end)

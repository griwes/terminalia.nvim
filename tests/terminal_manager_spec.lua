describe('terminal_manager', function()
    local history_dir
    local state_file

    ---@param fn fun(): boolean, string?
    ---@return boolean, string?, string[]
    local function with_notifications(fn)
        local notifications = {}
        local original_notify = vim.notify

        vim.notify = function(message)
            table.insert(notifications, message)
        end

        local ok, err = pcall(fn)

        vim.notify = original_notify

        return ok, err, notifications
    end

    before_each(function()
        local plugin = require('terminal_manager')
        history_dir = vim.fn.tempname()
        state_file = vim.fn.tempname()

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = state_file,
        })
        plugin.api.clear()
    end)

    it('loads and exposes setup', function()
        local plugin = require('terminal_manager')

        assert.are.equal('function', type(plugin.setup))
        assert.are.equal('split', plugin.config.default_view)
    end)

    it('rejects terminal ids with path separators', function()
        local plugin = require('terminal_manager')

        assert.has_error(function()
            plugin.api.create({
                id = '../escape',
                name = 'bad',
            })
        end, 'Invalid terminal id: "../escape"')
    end)

    it('creates an in-memory terminal record through the public api', function()
        local plugin = require('terminal_manager')

        local terminal = plugin.api.create({
            name = 'build',
            namespace = 'workspace',
        })

        assert.are.equal('terminal:1', terminal.id)
        assert.are.equal('build', terminal.name)
        assert.are.equal('workspace', terminal.namespace)
        assert.are.equal('context:host', terminal.context_id)
        assert.are.same({ terminal }, plugin.api.list())
    end)

    it('tracks a current host context by default', function()
        local plugin = require('terminal_manager')

        local current = plugin.api.current_context()
        local listed = plugin.api.list_contexts()

        assert.are.equal('context:host', current.id)
        assert.are.equal('host', current.kind)
        assert.are.equal('Host', current.label)
        assert.are.equal(1, #listed)
        assert.are.equal('context:host', listed[1].id)
    end)

    it('registers a session contributor when session.nvim is available', function()
        local plugin = require('terminal_manager')
        local observed = nil
        local original_session = package.loaded.session

        package.loaded.session = {
            api = {
                register_contributor = function(name, contributor)
                    observed = {
                        name = name,
                        contributor = contributor,
                    }
                end,
            },
        }

        local ok, err = pcall(function()
            plugin.setup({
                history_dir = history_dir,
                notify_on_exit = false,
                state_file = state_file,
            })
        end)

        package.loaded.session = original_session

        assert.is_true(ok, err)
        assert.are.equal('terminal_manager', assert(observed).name)
        assert.is_function(observed.contributor.capture)
        assert.is_function(observed.contributor.plan_restore)
        assert.are.same({ 'git_worktree', 'remote_workspace', 'devcontainer' }, observed.contributor.restore_after)
    end)

    it('captures terminal-manager logical state for session contributors', function()
        local plugin = require('terminal_manager')
        local context = plugin.api.create_child_context(plugin.api.host_context().id, {
            kind = 'fixture',
            label = 'fixture',
        })

        plugin.api.set_current_context(context.id)

        local terminal = plugin.api.create({
            name = 'build',
            namespace = 'workspace',
            cwd = '/tmp/workspace',
        })

        local captured = plugin.api.session_capture()

        assert.are.equal(context.id, captured.current_context_id)
        assert.are.equal(1, #captured.terminals)
        assert.are.equal(terminal.id, captured.terminals[1].id)
        assert.are.equal(context.id, captured.terminals[1].context_id)
        assert.is_true(vim.startswith(captured.terminals[1].uri, 'terminal-manager://'))
    end)

    it('builds restore-plan steps from captured terminal URIs', function()
        local plugin = require('terminal_manager')

        local steps = plugin.api.session_plan_restore({
            current_context_id = 'context:remote',
            terminals = {
                {
                    id = 'terminal:1',
                    uri = 'terminal-manager://terminal/terminal:1',
                    name = 'build',
                    namespace = 'workspace',
                    preferred_view = 'float',
                    disposable = false,
                },
            },
        })

        assert.are.equal(1, #steps)
        assert.are.equal('terminal_manager.reopen_terminals', steps[1].kind)
        assert.are.equal('terminal-manager://terminal/terminal:1', steps[1].payload.terminals[1].uri)
    end)

    it('notifies session.nvim when terminal-manager state changes', function()
        local plugin = require('terminal_manager')
        local notified = {}
        local original_session = package.loaded.session

        package.loaded.session = {
            api = {
                notify_contributor_changed = function(name)
                    table.insert(notified, name)
                end,
            },
        }

        local context = plugin.api.create_child_context(plugin.api.host_context().id, {
            kind = 'fixture',
            label = 'fixture',
        })
        local terminal = plugin.api.create({
            name = 'build',
        })

        plugin.api.set_current_context(context.id)
        plugin.api.update(terminal.id, {
            namespace = 'workspace',
        })
        plugin.api.delete(terminal.id)

        package.loaded.session = original_session

        assert.are.same({
            'terminal_manager',
            'terminal_manager',
            'terminal_manager',
            'terminal_manager',
            'terminal_manager',
        }, notified)
    end)

    it('creates child terminal contexts and can set the current context', function()
        local plugin = require('terminal_manager')

        local context = plugin.api.create_child_context(plugin.api.host_context().id, {
            kind = 'devcontainer',
            label = 'app-dev',
            metadata = {
                devcontainer_id = 'devcontainer:1',
            },
        })

        local current = plugin.api.set_current_context(context.id)

        assert.are.equal('devcontainer', context.kind)
        assert.are.equal('context:host', context.parent_id)
        assert.are.equal('app-dev', current.label)
        assert.are.equal('devcontainer:1', current.metadata.devcontainer_id)
    end)

    it('binds created terminals to the current terminal context', function()
        local plugin = require('terminal_manager')

        local context = plugin.api.create_child_context(plugin.api.host_context().id, {
            kind = 'remote_workspace',
            label = 'devbox',
        })

        plugin.api.set_current_context(context.id)

        local terminal = plugin.api.create({
            name = 'shell',
        })

        assert.are.equal(context.id, terminal.context_id)
        assert.are.same(
            { terminal },
            plugin.api.list({
                context_id = context.id,
            })
        )
    end)

    it('uses the current and explicit overseer contexts separately', function()
        local plugin = require('terminal_manager')

        local fixture = plugin.api.create_child_context(plugin.api.host_context().id, {
            kind = 'fixture',
            label = 'fixture',
        })

        plugin.api.register_context_provider('fixture', {
            plan_command = function(context, command)
                return {
                    context = context,
                    cmd = type(command) == 'table' and vim.deepcopy(command) or { 'sh', '-lc', command },
                    cwd = '/tmp/fixture',
                    default_name = 'fixture task',
                    terminal_name = 'fixture',
                    terminal_namespace = 'overseer',
                    metadata = {
                        fixture = {
                            context_id = context.id,
                        },
                    },
                }
            end,
        })

        plugin.api.set_current_context(fixture.id)

        local task = plugin.api.build_overseer_task({ 'echo', 'one' })

        assert.are.equal(fixture.id, task.metadata.terminal_manager.context_id)
        assert.are.equal(fixture.id, task.metadata.fixture.context_id)

        local host = plugin.api.host_context()
        plugin.api.set_overseer_context(host.id)

        local overridden = plugin.api.build_overseer_task({ 'echo', 'two' })

        assert.are.equal(host.id, plugin.api.overseer_context().id)
        assert.are.equal(host.id, overridden.metadata.terminal_manager.context_id)

        plugin.api.clear_overseer_context()

        assert.are.equal(fixture.id, plugin.api.overseer_context().id)
    end)

    it('uses configured default namespace for new terminals', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            state_file = state_file,
            default_namespace = 'workspace',
        })

        local terminal = plugin.api.create({
            name = 'build',
        })

        assert.are.equal('workspace', terminal.namespace)
    end)

    it('uses configured default view when opening a created terminal', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            state_file = state_file,
            default_view = 'float',
        })

        local terminal = plugin.api.create({
            name = 'echo',
            command = { 'sh', '-lc', 'printf ready' },
        })

        local opened = plugin.api.open(terminal.id)
        local windows = vim.api.nvim_list_wins()
        local floating = false

        for _, winid in ipairs(windows) do
            if vim.api.nvim_win_get_buf(winid) == opened.bufnr then
                local cfg = vim.api.nvim_win_get_config(winid)
                if cfg.relative ~= '' then
                    floating = true
                    break
                end
            end
        end

        assert.are.equal('float', opened.preferred_view)
        assert.is_true(floating)
    end)

    it('does not force restore on initial setup when terminals already exist', function()
        package.loaded['terminal_manager'] = nil
        local fresh_plugin = require('terminal_manager')

        local terminal = fresh_plugin.api.create({
            name = 'build',
            namespace = 'workspace',
        })

        fresh_plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = state_file,
        })

        local terminals = fresh_plugin.api.list()
        assert.are.equal(1, #terminals)
        assert.are.equal(terminal.id, terminals[1].id)
        assert.are.equal('build', terminals[1].name)
    end)

    it('remaps restored legacy terminal ids to a safe id', function()
        local plugin = require('terminal_manager')

        vim.fn.writefile({
            vim.json.encode({
                next_id = 3,
                terminals = {
                    {
                        id = 'legacy/id',
                        name = 'legacy',
                        namespace = 'default',
                        disposable = false,
                        cwd = '/tmp/legacy',
                        status = 'registered',
                        view = 'split',
                        created_at = 1,
                    },
                },
            }),
        }, state_file)

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = state_file,
        })

        local restored = plugin.api.list()[1]
        assert.is_truthy(restored)
        assert.are.equal('restored_terminal', restored.id)
        assert.are.equal('legacy', restored.name)
        assert.are.equal('/tmp/legacy', restored.cwd)
        assert.is_nil(plugin.api.get('legacy/id'))
        assert.are.equal(1, #plugin.api.list())
    end)

    it('restores multiple legacy terminal ids with distinct safe ids', function()
        local plugin = require('terminal_manager')

        vim.fn.writefile({
            vim.json.encode({
                next_id = 3,
                terminals = {
                    {
                        id = 'legacy/id',
                        name = 'legacy-one',
                        namespace = 'default',
                        disposable = false,
                        cwd = '/tmp/legacy-one',
                        status = 'registered',
                        view = 'split',
                        created_at = 1,
                    },
                    {
                        id = 'legacy?id',
                        name = 'legacy-two',
                        namespace = 'default',
                        disposable = false,
                        cwd = '/tmp/legacy-two',
                        status = 'registered',
                        view = 'split',
                        created_at = 2,
                    },
                },
            }),
        }, state_file)

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = state_file,
        })

        local restored = plugin.api.list()
        assert.are.equal(2, #restored)
        assert.are.equal('restored_terminal', restored[1].id)
        assert.are.equal('restored_terminal:2', restored[2].id)
        assert.are.equal('legacy-one', restored[1].name)
        assert.are.equal('legacy-two', restored[2].name)
        assert.are.equal('/tmp/legacy-one', restored[1].cwd)
        assert.are.equal('/tmp/legacy-two', restored[2].cwd)
        assert.is_truthy(plugin.api.get('restored_terminal'))
        assert.is_truthy(plugin.api.get('restored_terminal:2'))
    end)

    it('uses placeholder name for unnamed restored legacy terminals', function()
        local plugin = require('terminal_manager')

        vim.fn.writefile({
            vim.json.encode({
                next_id = 3,
                terminals = {
                    {
                        id = 'legacy/id',
                        namespace = 'default',
                        disposable = false,
                        cwd = '/tmp/legacy',
                        status = 'registered',
                        view = 'split',
                        created_at = 1,
                    },
                },
            }),
        }, state_file)

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = state_file,
        })

        local restored = plugin.api.list()[1]
        assert.is_truthy(restored)
        assert.are.equal('restored_terminal', restored.id)
        assert.are.equal('restored_terminal', restored.name)
        assert.are.equal(1, #plugin.api.list())
    end)

    it('restores persisted terminal metadata during setup without restarting jobs', function()
        local plugin = require('terminal_manager')

        plugin.api.create({
            name = 'build',
            namespace = 'workspace',
            cwd = '/tmp/workspace',
            env = {
                TERMINAL_MANAGER_PERSIST_TEST = 'persisted',
            },
        })
        plugin.api.set_cwd('terminal:1', '/tmp/workspace/subdir')
        plugin.api.clear({
            wipe_storage = false,
        })

        plugin.setup({
            notify_on_exit = false,
            state_file = state_file,
        })

        local restored = assert(plugin.api.get('terminal:1'))

        assert.are.equal('build', restored.name)
        assert.are.equal('/tmp/workspace/subdir', restored.cwd)
        assert.are.same({ TERMINAL_MANAGER_PERSIST_TEST = 'persisted' }, restored.env)
        assert.are.equal('registered', restored.status)
        assert.is_nil(restored.job_id)
        assert.is_nil(restored.bufnr)
    end)

    it('restores persisted terminal contexts and current context selection during setup', function()
        local plugin = require('terminal_manager')

        plugin.api.create_context({
            id = 'context:devcontainer',
            kind = 'devcontainer',
            label = 'app-dev',
            parent_id = 'context:host',
            metadata = {
                devcontainer_id = 'devcontainer:1',
            },
        })
        plugin.api.set_current_context('context:devcontainer')
        plugin.api.create({
            name = 'build',
        })
        plugin.api.clear({
            wipe_storage = false,
        })

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = state_file,
        })

        local restored_context = plugin.api.current_context()
        local restored_terminal = assert(plugin.api.get('terminal:1'))

        assert.are.equal('context:devcontainer', restored_context.id)
        assert.are.equal('devcontainer', restored_context.kind)
        assert.are.equal('devcontainer:1', restored_context.metadata.devcontainer_id)
        assert.are.equal('context:devcontainer', restored_terminal.context_id)
    end)

    it('reloads persisted terminals after clear resets setup persistence state', function()
        local plugin = require('terminal_manager')

        plugin.api.create({
            name = 'build',
        })
        plugin.api.clear({
            wipe_storage = false,
        })

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = state_file,
        })

        local restored = assert(plugin.api.get('terminal:1'))

        assert.are.equal('build', restored.name)
        assert.are.equal(1, #plugin.api.list())
    end)

    it('restores persisted terminals when enabling persistence after terminals already exist', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = false,
            state_file = state_file,
        })

        plugin.api.create({
            name = 'live',
        })

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = state_file,
        })

        plugin.api.create({
            name = 'live',
        })

        plugin.api.clear({
            wipe_storage = false,
        })

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = false,
            state_file = state_file,
        })

        plugin.api.create({
            name = 'session',
        })

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = state_file,
        })

        assert.are.equal('session', assert(plugin.api.get('terminal:1')).name)
        assert.are.equal('live', assert(plugin.api.get('terminal:2')).name)
        assert.are.equal(2, #plugin.api.list())
        assert.is_not_nil(plugin.api.get('terminal:1'))
    end)

    it('keeps in-memory terminals when merged persisted terminals reuse the same ids', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = state_file,
        })

        plugin.api.create({
            name = 'persisted',
        })

        plugin.api.clear({
            wipe_storage = false,
        })

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = false,
            state_file = state_file,
        })

        plugin.api.create({
            name = 'session',
        })

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = state_file,
        })

        assert.are.equal('session', assert(plugin.api.get('terminal:1')).name)
        assert.are.equal('persisted', assert(plugin.api.get('terminal:2')).name)
        assert.are.equal(2, #plugin.api.list())
        assert.is_not_nil(plugin.api.get('terminal:1'))
    end)

    it('does not tear down runtime state on initial setup without persisted state', function()
        local plugin = require('terminal_manager')
        plugin.api.create({
            name = 'session',
        })

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = false,
            state_file = state_file,
        })

        assert.are.equal('session', assert(plugin.api.get('terminal:1')).name)
        assert.are.equal(1, #plugin.api.list())
    end)

    it('clears persisted state when terminal persistence is disabled', function()
        local plugin = require('terminal_manager')
        local first_state_file = vim.fn.tempname()

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = first_state_file,
        })
        plugin.api.clear()
        plugin.api.create({
            name = 'persisted',
        })

        assert.are.equal(1, vim.fn.filereadable(first_state_file))

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = false,
            state_file = first_state_file,
        })

        assert.are.equal(0, vim.fn.filereadable(first_state_file))
        assert.are.equal('persisted', assert(plugin.api.get('terminal:1')).name)
        assert.are.equal(1, #plugin.api.list())
    end)

    it('keeps existing persistence settings on repeated partial setup', function()
        local plugin = require('terminal_manager')
        local custom_state_file = vim.fn.tempname()

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = false,
            state_file = custom_state_file,
        })

        plugin.setup({
            default_view = 'float',
        })

        assert.is_false(plugin.config.persist_terminals)
        assert.are.equal(custom_state_file, plugin.config.state_file)
        assert.are.equal('float', plugin.config.default_view)
    end)

    it('clears both persistence files when disabling persistence and switching state files', function()
        local plugin = require('terminal_manager')
        local first_state_file = vim.fn.tempname()
        local second_state_file = vim.fn.tempname()

        vim.fn.writefile(
            { vim.json.encode({ terminals = { { id = 'terminal:1', name = 'stale' } } }) },
            second_state_file
        )

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = first_state_file,
        })
        plugin.api.clear()
        plugin.api.create({
            name = 'persisted',
        })

        assert.are.equal(1, vim.fn.filereadable(first_state_file))
        assert.are.equal(1, vim.fn.filereadable(second_state_file))

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = false,
            state_file = second_state_file,
        })

        assert.are.equal(0, vim.fn.filereadable(first_state_file))
        assert.are.equal(0, vim.fn.filereadable(second_state_file))
    end)

    it('tears down running terminals before force-restoring a different state file', function()
        local plugin = require('terminal_manager')
        local first_state_file = vim.fn.tempname()
        local second_state_file = vim.fn.tempname()

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            state_file = first_state_file,
            persist_history = false,
        })
        plugin.api.clear()

        local terminal = plugin.api.create({
            name = 'running',
            command = { 'sh', '-lc', 'sleep 5' },
        })

        plugin.api.start(terminal.id)
        assert.are.equal('running', assert(plugin.api.get(terminal.id)).status)

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            state_file = second_state_file,
            persist_history = false,
        })

        assert.is_nil(plugin.api.get(terminal.id))
        assert.are.same({}, plugin.api.list())
    end)

    it('wipes tracked buffers before force-restoring registry state', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            state_file = state_file,
            persist_history = false,
        })

        local terminal = plugin.api.create({
            name = 'buffered',
            command = { 'sh', '-lc', 'sleep 5' },
        })

        plugin.api.start(terminal.id)

        local bufnr = assert(plugin.api.get(terminal.id)).bufnr
        assert.is_true(vim.api.nvim_buf_is_valid(bufnr))

        vim.fn.writefile({
            vim.json.encode({
                next_id = 2,
                terminals = {
                    {
                        id = 'terminal:1',
                        name = 'restored',
                        namespace = 'default',
                        disposable = false,
                        cwd = vim.loop.cwd(),
                        status = 'registered',
                        view = 'split',
                        created_at = 1,
                    },
                },
            }),
        }, state_file)

        plugin.api.restore({
            force = true,
            merge = false,
        })

        assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
        assert.are.equal('restored', assert(plugin.api.get('terminal:1')).name)
    end)

    it('preserves destination persisted state when switching state files', function()
        local plugin = require('terminal_manager')
        local first_state_file = vim.fn.tempname()
        local second_state_file = vim.fn.tempname()

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = first_state_file,
        })
        plugin.api.clear()
        plugin.api.create({
            name = 'first',
        })

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = second_state_file,
        })
        plugin.api.create({
            name = 'second',
        })

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = second_state_file,
        })

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = first_state_file,
        })

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = second_state_file,
        })

        local restored = assert(plugin.api.get('terminal:1'))

        assert.are.equal('second', restored.name)
        assert.are.equal(1, #plugin.api.list())
    end)

    it('reloads persisted terminals when persistence config changes', function()
        local plugin = require('terminal_manager')
        local first_state_file = vim.fn.tempname()
        local second_state_file = vim.fn.tempname()

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = first_state_file,
        })
        plugin.api.clear()
        plugin.api.create({
            name = 'first',
        })

        plugin.api.clear({
            wipe_storage = false,
        })

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = second_state_file,
        })

        plugin.api.create({
            name = 'second',
        })

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = first_state_file,
        })

        local restored = assert(plugin.api.get('terminal:1'))

        assert.are.equal('first', restored.name)
        assert.are.equal(1, #plugin.api.list())
    end)

    it('creates runtime buffers as unlisted buffers', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = false,
            state_file = state_file,
        })

        local terminal = plugin.api.create({
            name = 'hidden-buffer',
        })

        plugin.api.start(terminal.id)

        local current = assert(plugin.api.get(terminal.id))
        assert.is_truthy(current.bufnr)
        assert.are.equal(0, vim.fn.buflisted(current.bufnr))
    end)

    it('sanitizes invalid env entries on update and persistence', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = false,
            state_file = state_file,
        })

        local terminal = plugin.api.create({
            name = 'env-sanitize',
            env = {
                KEEP = 'value',
            },
        })

        plugin.api.update(terminal.id, {
            env = {
                KEEP = 'updated',
                DROP_NUMBER = 42,
                [9] = 'bad-key',
                DROP_BOOL = true,
            },
        })

        local current = assert(plugin.api.get(terminal.id))
        assert.are.same({ KEEP = 'updated' }, current.env)

        plugin.api.clear({
            wipe_storage = false,
        })
        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = false,
            state_file = state_file,
        })

        local restored = assert(plugin.api.get('terminal:1'))
        assert.are.same({ KEEP = 'updated' }, restored.env)
    end)

    it('starts terminals using the latest registry cwd and env values', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = false,
            state_file = state_file,
        })

        local temp_dir = vim.fn.tempname()
        vim.fn.mkdir(temp_dir, 'p')

        local terminal = plugin.api.create({
            name = 'env-cwd',
            cwd = '/tmp',
            env = {
                TERMINAL_MANAGER_RUNTIME_TEST = 'old',
            },
            command = {
                'sh',
                '-lc',
                'printf "%s|%s" "$PWD" "$TERMINAL_MANAGER_RUNTIME_TEST"',
            },
        })

        plugin.api.set_cwd(terminal.id, temp_dir)
        local updated = assert(plugin.api.get(terminal.id))
        updated.env = {
            TERMINAL_MANAGER_RUNTIME_TEST = 'new',
        }

        plugin.api.start(terminal.id)
        plugin.api.wait(terminal.id, 2000)

        assert.are.equal(temp_dir .. '|new', plugin.api.output(terminal.id).output)
    end)

    it('captures terminal history durably and restores it across setup', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = true,
            state_file = state_file,
        })

        local terminal = plugin.api.create({
            name = 'build',
            command = { 'sh', '-lc', 'printf "one\\ntwo\\n"' },
        })

        plugin.api.open(terminal.id)

        vim.wait(2000, function()
            local current = assert(plugin.api.get(terminal.id))
            return current.status == 'exited'
        end, 20)

        assert.are.same({ 'one', 'two' }, plugin.api.history_lines(terminal.id))

        plugin.api.clear({
            wipe_storage = false,
        })
        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            state_file = state_file,
        })

        assert.are.same({ 'one', 'two' }, plugin.api.history_lines(terminal.id))
    end)

    it('reconstructs partial history chunks across callback boundaries', function()
        local plugin = require('terminal_manager')
        local history = require('terminal_manager.history')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = true,
            state_file = state_file,
        })

        history.append_chunks('terminal:partial', { 'al' })
        history.append_chunks('terminal:partial', { 'pha', 'beta', '' })
        history.flush('terminal:partial')

        assert.are.same({ 'alpha', 'beta' }, history.read_lines('terminal:partial'))
    end)

    it('does not restore disposable terminals from persisted metadata', function()
        local plugin = require('terminal_manager')

        plugin.api.create({
            name = 'scratch',
            disposable = true,
            cwd = '/tmp/scratch',
        })
        plugin.api.clear({
            wipe_storage = false,
        })

        plugin.setup({
            notify_on_exit = false,
            state_file = state_file,
        })

        assert.is_nil(plugin.api.get('terminal:1'))
        assert.are.same({}, plugin.api.list())
    end)

    it('restores next_id as a lower bound while ignoring malformed terminal IDs', function()
        local plugin = require('terminal_manager')
        local terminals = {
            {
                id = 'terminal:1',
                name = 'build',
                namespace = 'workspace',
                disposable = false,
                cwd = '/tmp/workspace',
                status = 'registered',
                view = 'split',
                created_at = 1,
            },
            {
                id = 'terminal:3',
                name = 'lint',
                namespace = 'workspace',
                disposable = false,
                cwd = '/tmp/other',
                status = 'registered',
                view = 'split',
                created_at = 1,
            },
            {
                id = 'terminal:bogus',
                name = 'invalid',
                namespace = 'workspace',
                disposable = false,
                cwd = '/tmp/invalid',
                status = 'registered',
                view = 'split',
                created_at = 1,
            },
            {
                id = 7,
                name = 'invalid-id-type',
                namespace = 'workspace',
                disposable = false,
                cwd = '/tmp/invalid',
                status = 'registered',
                view = 'split',
                created_at = 1,
            },
        }

        vim.fn.writefile({
            vim.json.encode({
                next_id = 99,
                terminals = terminals,
            }),
        }, state_file)

        plugin.setup({
            notify_on_exit = false,
            state_file = state_file,
        })

        local restored_new = plugin.api.create({})
        assert.are.equal('terminal:99', restored_new.id)
        assert.are.equal('build', assert(plugin.api.get('terminal:1')).name)
        assert.are.equal('invalid', assert(plugin.api.get('terminal:bogus')).name)
        assert.is_nil(plugin.api.get('7'))
    end)

    it('does not clobber active registry state on repeated setup calls', function()
        local plugin = require('terminal_manager')

        plugin.api.create({
            name = 'build',
            namespace = 'workspace',
        })

        plugin.setup({
            notify_on_exit = false,
            state_file = state_file,
            default_view = 'float',
        })

        local items = plugin.api.list()

        assert.are.equal(1, #items)
        assert.are.equal('build', items[1].name)
        assert.are.equal('float', plugin.config.default_view)
    end)

    it('preserves omitted paths on repeated setup', function()
        local plugin = require('terminal_manager')
        local custom_history_dir = vim.fn.tempname()
        local custom_state_file = vim.fn.tempname()

        plugin.setup({
            history_dir = custom_history_dir,
            notify_on_exit = false,
            state_file = custom_state_file,
        })

        plugin.setup({
            default_view = 'float',
        })

        assert.are.equal(custom_history_dir, plugin.config.history_dir)
        assert.are.equal(custom_state_file, plugin.config.state_file)
        assert.are.equal('float', plugin.config.default_view)
    end)

    it('preserves omitted non-path options on repeated setup', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            history_dir = history_dir,
            default_view = 'float',
            notify_on_exit = false,
            state_file = state_file,
        })

        plugin.setup({
            notify_on_exit = false,
        })

        assert.are.equal('float', plugin.config.default_view)
        assert.is_false(plugin.config.notify_on_exit)
        assert.are.equal(history_dir, plugin.config.history_dir)
        assert.are.equal(state_file, plugin.config.state_file)
    end)

    it('keeps the exported config table reference fresh across setup calls', function()
        local plugin = require('terminal_manager')
        local cached_config = plugin.config

        plugin.setup({
            notify_on_exit = false,
            state_file = state_file,
            default_view = 'float',
        })

        assert.are.equal(cached_config, plugin.config)
        assert.are.equal('float', cached_config.default_view)
    end)

    it('registers user commands on plugin load', function()
        local commands = vim.api.nvim_get_commands({})

        assert.is_truthy(commands.TerminalManagerNew)
        assert.is_truthy(commands.TerminalManagerOpen)
        assert.is_truthy(commands.TerminalManagerList)
        assert.is_truthy(commands.TerminalManagerHistory)
    end)

    it('completes terminal ids for open and history commands', function()
        local plugin = require('terminal_manager')
        local terminal = plugin.api.create({
            name = 'build',
            namespace = 'workspace',
        })
        local commands = vim.api.nvim_get_commands({})

        assert.is_function(commands.TerminalManagerOpen.complete)
        assert.is_function(commands.TerminalManagerHistory.complete)
        assert.are.same({ terminal.id }, commands.TerminalManagerOpen.complete('', 'TerminalManagerOpen ', 0))
        assert.are.same({ terminal.id }, commands.TerminalManagerHistory.complete('', 'TerminalManagerHistory ', 0))
    end)

    it('completes namespaces, cwd prefixes, and view kinds for terminal commands', function()
        local plugin = require('terminal_manager')
        local terminal = plugin.api.create({
            name = 'build',
            namespace = 'workspace',
            cwd = '/tmp/workspace',
        })
        local commands = vim.api.nvim_get_commands({})

        assert.are.equal(terminal.id, plugin.api.list()[1].id)
        assert.are.same({ 'workspace' }, commands.TerminalManagerNew.complete('w', 'TerminalManagerNew build w', 0))
        assert.are.same(
            { 'split' },
            commands.TerminalManagerNew.complete('s', 'TerminalManagerNew build workspace s', 0)
        )
        assert.are.same({ 'float' }, commands.TerminalManagerOpen.complete('f', 'TerminalManagerOpen terminal:1 f', 0))
        assert.are.same({ 'workspace' }, commands.TerminalManagerList.complete('w', 'TerminalManagerList w', 0))
        assert.are.same(
            { '/tmp/workspace' },
            commands.TerminalManagerList.complete('/tmp/w', 'TerminalManagerList workspace /tmp/w', 0)
        )
        assert.are.same({}, commands.TerminalManagerNew.complete('', 'TerminalManagerNew build workspace split ', 0))
        assert.are.same({}, commands.TerminalManagerOpen.complete('', 'TerminalManagerOpen terminal:1 float ', 0))
        assert.are.same(
            {},
            commands.TerminalManagerList.complete('', 'TerminalManagerList workspace /tmp/workspace extra', 0)
        )
    end)

    it('creates a terminal through the user command surface', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            notify_on_exit = false,
            shell = { 'sh', '-lc', 'printf ready' },
            state_file = state_file,
        })

        vim.cmd('TerminalManagerNew build workspace split')

        local items = plugin.api.list()

        assert.are.equal(1, #items)
        assert.are.equal('build', items[1].name)
        assert.are.equal('workspace', items[1].namespace)
        assert.are.equal('running', items[1].status)
    end)

    it('creates a terminal with quoted multi-word command arguments', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            notify_on_exit = false,
            shell = { 'sh', '-lc', 'printf ready' },
            state_file = state_file,
        })

        vim.cmd([[TerminalManagerNew "build task" "shared workspace" float]])

        local items = plugin.api.list()

        assert.are.equal(1, #items)
        assert.are.equal('build task', items[1].name)
        assert.are.equal('shared workspace', items[1].namespace)
        assert.are.equal('float', items[1].preferred_view)
    end)

    it('creates a terminal with escaped quotes inside quoted command arguments', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            notify_on_exit = false,
            shell = { 'sh', '-lc', 'printf ready' },
            state_file = state_file,
        })

        vim.cmd([=[TerminalManagerNew "build \"fast\" task" "shared \"quoted\" workspace" float]=])

        local items = plugin.api.list()

        assert.are.equal(1, #items)
        assert.are.equal('build "fast" task', items[1].name)
        assert.are.equal('shared "quoted" workspace', items[1].namespace)
        assert.are.equal('float', items[1].preferred_view)
    end)

    it('preserves literal backslashes inside quoted command arguments', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            notify_on_exit = false,
            shell = { 'sh', '-lc', 'printf ready' },
            state_file = state_file,
        })

        vim.cmd([=[TerminalManagerNew "C:\\tmp\\build" "shared\\workspace" float]=])

        local items = plugin.api.list()

        assert.are.equal(1, #items)
        assert.are.equal([[C:\\tmp\\build]], items[1].name)
        assert.are.equal([[shared\\workspace]], items[1].namespace)
        assert.are.equal('float', items[1].preferred_view)
    end)

    it('follows Neovim parsing for trailing backslashes inside quoted command arguments', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            notify_on_exit = false,
            shell = { 'sh', '-lc', 'printf ready' },
            state_file = state_file,
        })

        vim.cmd([=[TerminalManagerNew "C:\\tmp\\" "shared\\" float]=])

        local items = plugin.api.list()

        assert.are.equal(1, #items)
        assert.are.equal([[C:\\tmp\]], items[1].name)
        assert.are.equal([[shared\]], items[1].namespace)
        assert.are.equal('float', items[1].preferred_view)
    end)

    it('preserves even backslash runs before quotes inside quoted command arguments', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            notify_on_exit = false,
            shell = { 'sh', '-lc', 'printf ready' },
            state_file = state_file,
        })

        vim.cmd([=[TerminalManagerNew "C:\\\"" "shared\\\"" float]=])

        local items = plugin.api.list()

        assert.are.equal(1, #items)
        assert.are.equal([[C:\"]], items[1].name)
        assert.are.equal([[shared\"]], items[1].namespace)
        assert.are.equal('float', items[1].preferred_view)
    end)

    it('treats unterminated quoted command arguments as a single trailing argument', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            notify_on_exit = false,
            shell = { 'sh', '-lc', 'printf ready' },
            state_file = state_file,
        })

        vim.cmd([[TerminalManagerNew "build task workspace split]])

        local items = plugin.api.list()

        assert.are.equal(1, #items)
        assert.are.equal('build task workspace split', items[1].name)
        assert.are.equal(plugin.config.default_namespace, items[1].namespace)
        assert.are.equal(plugin.config.default_view, items[1].preferred_view)
    end)

    it('parses mixed quoted and unquoted command arguments with extra whitespace', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            notify_on_exit = false,
            shell = { 'sh', '-lc', 'printf ready' },
            state_file = state_file,
        })

        vim.cmd([[TerminalManagerNew   build   "shared workspace"   float]])

        local items = plugin.api.list()

        assert.are.equal(1, #items)
        assert.are.equal('build', items[1].name)
        assert.are.equal('shared workspace', items[1].namespace)
        assert.are.equal('float', items[1].preferred_view)
    end)

    it('opens a terminal buffer through the public api', function()
        local plugin = require('terminal_manager')

        local terminal = plugin.api.create({
            name = 'echo',
            command = { 'sh', '-lc', 'printf ready' },
            view = 'split',
        })

        local opened = plugin.api.open(terminal.id)
        local bufnr = assert(opened.bufnr)
        local job_id = assert(opened.job_id)

        assert.are.equal('running', opened.status)
        assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
        assert.is_true(job_id > 0)
    end)

    it('starts terminals in terminal buffers', function()
        local plugin = require('terminal_manager')

        local terminal = plugin.api.create({
            name = 'echo',
            command = { 'sh', '-lc', 'printf ready' },
        })

        local opened = plugin.api.start(terminal.id)
        local bufnr = assert(opened.bufnr)

        vim.wait(2000, function()
            return vim.bo[bufnr].buftype == 'terminal'
        end, 20)

        assert.are.equal('terminal', vim.bo[bufnr].buftype)
    end)

    it('falls back to a safe split direction when configured direction is invalid', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            split_direction = 'botright | qall!',
            state_file = state_file,
        })

        local terminal = plugin.api.create({
            name = 'echo',
            command = { 'sh', '-lc', 'printf ready' },
            view = 'split',
        })

        local opened = plugin.api.open(terminal.id)

        assert.are.equal('running', opened.status)
        assert.truthy(opened.bufnr)
        assert.is_true(vim.api.nvim_buf_is_valid(opened.bufnr))
    end)

    it('starts a terminal without opening a view and returns captured output', function()
        local plugin = require('terminal_manager')
        local original_bufnr = vim.api.nvim_get_current_buf()

        local terminal = plugin.api.create({
            name = 'echo',
            command = { 'sh', '-lc', 'printf ready' },
        })

        plugin.api.start(terminal.id)
        local exited = plugin.api.wait(terminal.id, 2000)
        local output = plugin.api.output(terminal.id)

        assert.are.equal(original_bufnr, vim.api.nvim_get_current_buf())
        assert.are_not.equal(original_bufnr, assert(plugin.api.get(terminal.id)).bufnr)
        assert.are.equal('exited', assert(exited).status)
        assert.are.equal(0, exited.exit_code)
        assert.are.same({
            output = 'ready',
            status = 'exited',
            exit_code = 0,
        }, output)
    end)

    it('returns live output even when history persistence is disabled', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = false,
            state_file = state_file,
        })

        local terminal = plugin.api.create({
            name = 'echo',
            command = { 'sh', '-lc', 'printf transient' },
        })

        plugin.api.start(terminal.id)
        local exited = plugin.api.wait(terminal.id, 2000)

        assert.are.equal('transient', plugin.api.output(terminal.id).output)
        assert.are.equal('exited', assert(exited).status)
        vim.wait(2000, function()
            return #plugin.api.history_lines(terminal.id) == 0
        end, 20)
        assert.are.same({}, plugin.api.history_lines(terminal.id))
    end)

    it('passes request-scoped environment variables into the terminal job', function()
        local plugin = require('terminal_manager')

        local terminal = plugin.api.create({
            name = 'env',
            command = { 'sh', '-lc', 'printf "$TERMINAL_MANAGER_TEST_VALUE"' },
            env = {
                TERMINAL_MANAGER_TEST_VALUE = 'from-env',
            },
        })

        plugin.api.start(terminal.id)
        plugin.api.wait(terminal.id, 2000)

        assert.are.equal('from-env', plugin.api.output(terminal.id).output)
    end)

    it('preserves inherited environment when extending terminal env', function()
        local plugin = require('terminal_manager')
        local original_path = vim.env.PATH

        assert.is_truthy(original_path and original_path ~= '')

        local terminal = plugin.api.create({
            name = 'env-path',
            command = { 'sh', '-lc', 'printf "%s|%s" "$PATH" "$TERMINAL_MANAGER_TEST_VALUE"' },
            env = {
                TERMINAL_MANAGER_TEST_VALUE = 'from-env',
            },
        })

        plugin.api.start(terminal.id)
        plugin.api.wait(terminal.id, 2000)

        local output = plugin.api.output(terminal.id).output
        local job_path, marker = output:match('^(.*)|(.*)$')

        assert.are.equal('from-env', marker)
        assert.is_not_nil(job_path)
        assert.is_true(job_path:find('/usr/bin', 1, true) ~= nil)
        assert.is_true(job_path:find('/bin', 1, true) ~= nil)
        assert.is_true(job_path:find(original_path, 1, true) ~= nil or original_path:find(job_path, 1, true) ~= nil)
    end)

    it('kills a running terminal through the public api', function()
        local plugin = require('terminal_manager')

        local terminal = plugin.api.create({
            name = 'sleep',
            command = { 'sh', '-lc', 'sleep 5' },
        })

        plugin.api.start(terminal.id)
        plugin.api.kill(terminal.id)
        local exited = plugin.api.wait(terminal.id, 2000)

        assert.is_not_nil(exited)
        assert.are.equal('exited', exited.status)
    end)

    it('releases a running terminal through the public api', function()
        local plugin = require('terminal_manager')

        local terminal = plugin.api.create({
            name = 'sleep',
            command = { 'sh', '-lc', 'sleep 5' },
        })

        plugin.api.start(terminal.id)
        local released = plugin.api.release(terminal.id)

        assert.are.equal(terminal.id, assert(released).id)
        assert.is_nil(plugin.api.get(terminal.id))
        assert.has_error(function()
            plugin.api.output(terminal.id)
        end, 'Unknown terminal id: ' .. terminal.id)
    end)

    it('returns exited metadata when releasing disposable terminals after wait', function()
        local plugin = require('terminal_manager')

        local terminal = plugin.api.create({
            name = 'echo',
            command = { 'sh', '-lc', 'printf released' },
            disposable = true,
        })

        plugin.api.start(terminal.id)
        local exited = plugin.api.wait(terminal.id, 1000)
        local released = plugin.api.release(terminal.id)

        assert.are.equal('exited', assert(exited).status)
        assert.are.equal(terminal.id, assert(released).id)
        assert.are.equal('echo', released.name)
        assert.is_nil(plugin.api.get(terminal.id))
        assert.has_error(function()
            plugin.api.output(terminal.id)
        end, 'Unknown terminal id: ' .. terminal.id)
        assert.has_error(function()
            plugin.api.history_lines(terminal.id)
        end, 'Unknown terminal id: ' .. terminal.id)
    end)

    it('returns nil when releasing already-pruned exited disposable terminals', function()
        local plugin = require('terminal_manager')
        local runtime = require('terminal_manager.runtime.native')

        local terminal = plugin.api.create_and_open({
            name = 'echo',
            command = { 'sh', '-lc', 'printf released' },
            disposable = true,
        })
        local bufnr = assert(terminal.bufnr)

        local exited = plugin.api.wait(terminal.id, 1000)

        assert.are.equal('exited', assert(exited).status)
        assert.is_nil(plugin.api.get(terminal.id))
        assert.is_not_nil(runtime.exited_terminal(terminal.id))

        vim.cmd('close')
        vim.api.nvim_exec_autocmds('BufHidden', {
            buffer = bufnr,
            modeline = false,
        })
        vim.wait(2000, function()
            return runtime.exited_terminal(terminal.id) == nil
        end, 20)

        assert.is_nil(plugin.api.release(terminal.id))
        assert.has_error(function()
            plugin.api.output(terminal.id)
        end, 'Unknown terminal id: ' .. terminal.id)
        assert.has_error(function()
            plugin.api.history_lines(terminal.id)
        end, 'Unknown terminal id: ' .. terminal.id)
    end)

    it('returns exited terminal metadata when releasing a known runtime terminal', function()
        local plugin = require('terminal_manager')
        local runtime = require('terminal_manager.runtime.native')

        local terminal = plugin.api.create_and_open({
            name = 'echo',
            command = { 'sh', '-lc', 'printf released' },
            disposable = true,
        })
        local bufnr = terminal.bufnr

        local exited = plugin.api.wait(terminal.id, 1000)

        assert.are.equal('exited', assert(exited).status)

        vim.api.nvim_exec_autocmds('BufHidden', {
            buffer = bufnr,
            modeline = false,
        })
        vim.wait(100, function()
            return false
        end, 20)

        assert.is_nil(plugin.api.get(terminal.id))
        assert.is_not_nil(runtime.exited_terminal(terminal.id))

        local released = plugin.api.release(terminal.id)

        assert.are.equal(terminal.id, assert(released).id)
        assert.are.equal('echo', released.name)
        assert.is_nil(runtime.exited_terminal(terminal.id))
        assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
    end)

    it('formats registered terminals for listing', function()
        local plugin = require('terminal_manager')

        plugin.api.create({
            name = 'build',
            namespace = 'workspace',
            cwd = '/tmp/workspace',
        })

        assert.are.same({
            'terminal:1  [workspace]  registered  /tmp/workspace  build',
        }, plugin.api.list_lines())
    end)

    it('formats missing terminal display fields safely when listing', function()
        local plugin = require('terminal_manager')

        vim.fn.writefile({
            vim.json.encode({
                next_id = 2,
                terminals = {
                    {
                        id = 'terminal:1',
                        cwd = '/tmp/workspace',
                        namespace = 'default',
                        status = 'registered',
                        view = 'split',
                        disposable = false,
                        created_at = os.time(),
                    },
                },
            }),
        }, state_file)

        plugin.api.clear({
            wipe_storage = false,
        })
        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = state_file,
        })

        assert.are.same({
            'terminal:1  [default]  registered  /tmp/workspace  restored_terminal',
        }, plugin.api.list_lines())
    end)

    it('filters listed terminals by namespace and cwd prefix', function()
        local plugin = require('terminal_manager')

        plugin.api.create({
            name = 'build',
            namespace = 'workspace',
            cwd = '/tmp/workspace',
        })
        plugin.api.create({
            name = 'lint',
            namespace = 'workspace',
            cwd = '/tmp/other',
        })
        plugin.api.create({
            name = 'shell',
            namespace = 'devcontainer',
            cwd = '/tmp/workspace/container',
        })

        local workspace_items = plugin.api.list({
            namespace = 'workspace',
            cwd_prefix = '/tmp/work',
        })

        assert.are.equal(1, #workspace_items)
        assert.are.equal('build', workspace_items[1].name)
    end)

    it('filters listed terminals through the user command surface', function()
        local plugin = require('terminal_manager')

        plugin.api.create({
            name = 'build',
            namespace = 'workspace',
            cwd = '/tmp/workspace',
        })
        plugin.api.create({
            name = 'shell',
            namespace = 'default',
            cwd = '/tmp/other',
        })

        local ok, err, notifications = with_notifications(function()
            vim.cmd('TerminalManagerList workspace /tmp/work')
        end)

        assert.is_true(ok, err)
        assert.are.same({
            'terminal:1  [workspace]  registered  /tmp/workspace  build',
        }, notifications)
    end)

    it('filters command-line listing by namespace and cwd prefix', function()
        local plugin = require('terminal_manager')

        plugin.api.create({
            name = 'build',
            namespace = 'workspace',
            cwd = '/tmp/workspace',
        })
        plugin.api.create({
            name = 'shell',
            namespace = 'devcontainer',
            cwd = '/tmp/workspace/container',
        })

        local ok, err, notifications = with_notifications(function()
            vim.cmd('TerminalManagerList workspace /tmp/workspace')
        end)

        assert.is_true(ok, err)
        assert.are.same({
            'terminal:1  [workspace]  registered  /tmp/workspace  build',
        }, notifications)
    end)

    it('filters quoted namespace listings the same as completion', function()
        local plugin = require('terminal_manager')

        plugin.api.create({
            name = 'build',
            namespace = 'workspace team',
            cwd = '/tmp/workspace dir',
        })
        plugin.api.create({
            name = 'shell',
            namespace = 'default',
            cwd = '/tmp/other',
        })

        local ok, err, notifications = with_notifications(function()
            vim.cmd([[TerminalManagerList "workspace team" /tmp/work]])
        end)

        assert.is_true(ok, err)
        assert.are.same({
            'terminal:1  [workspace team]  registered  /tmp/workspace dir  build',
        }, notifications)
    end)

    it('filters quoted namespace listings with multiple spaces in namespace', function()
        local plugin = require('terminal_manager')

        plugin.api.create({
            name = 'build',
            namespace = 'team alpha beta',
            cwd = '/tmp/x/project',
        })
        plugin.api.create({
            name = 'shell',
            namespace = 'team alpha',
            cwd = '/tmp/x/other',
        })

        local ok, err, notifications = with_notifications(function()
            vim.cmd([[TerminalManagerList "team alpha beta" /tmp/x/pro]])
        end)

        assert.is_true(ok, err)
        assert.are.same({
            'terminal:1  [team alpha beta]  registered  /tmp/x/project  build',
        }, notifications)
    end)

    it('reports when command-line filters match no terminals', function()
        local plugin = require('terminal_manager')
        local notifications = {}
        local original_notify = vim.notify

        plugin.api.create({
            name = 'build',
            namespace = 'workspace',
            cwd = '/tmp/workspace',
        })

        vim.notify = function(message)
            table.insert(notifications, message)
        end

        local ok, err = pcall(vim.cmd, 'TerminalManagerList devcontainer /tmp/missing')

        vim.notify = original_notify

        assert.is_true(ok, err)
        assert.are.same({
            'No terminals matched the requested filters',
        }, notifications)
    end)

    it('opens captured history through the user command surface', function()
        local plugin = require('terminal_manager')
        local uri = require('terminal_manager.uri')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = true,
            state_file = state_file,
        })
        local history = require('terminal_manager.history')

        local terminal = plugin.api.create({
            name = 'build',
        })

        history.append_chunks(terminal.id, { 'alpha', 'beta', '' })
        history.flush(terminal.id)

        assert.are.same({ 'alpha', 'beta' }, plugin.api.history_lines(terminal.id))

        vim.cmd(string.format('TerminalManagerHistory %s', terminal.id))

        local history_bufnr = vim.api.nvim_get_current_buf()

        assert.are.equal(uri.encode_history_uri(terminal), vim.api.nvim_buf_get_name(history_bufnr))
        assert.are.same({ 'alpha', 'beta' }, vim.api.nvim_buf_get_lines(history_bufnr, 0, -1, false))
    end)

    it('encodes active terminal names when opening history', function()
        local plugin = require('terminal_manager')
        local uri = require('terminal_manager.uri')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = true,
            state_file = state_file,
        })
        local history = require('terminal_manager.history')

        local terminal = plugin.api.create({
            name = 'dir/name\001',
        })

        history.append_chunks(terminal.id, { 'alpha', '' })
        history.flush(terminal.id)

        plugin.api.open_history(terminal.id)

        assert.are.equal(uri.encode_history_uri(terminal), vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
    end)

    it('rejects unknown ids for history inspection', function()
        local plugin = require('terminal_manager')

        assert.has_error(function()
            plugin.api.open_history('terminal:missing')
        end, 'Unknown terminal id: terminal:missing')
    end)

    it('rejects unknown ids for history line reads', function()
        local plugin = require('terminal_manager')

        assert.has_error(function()
            plugin.api.history_lines('terminal:missing')
        end, 'Unknown terminal id: terminal:missing')
    end)

    it('returns nil when deleting an unknown terminal id', function()
        local plugin = require('terminal_manager')

        assert.is_nil(plugin.api.delete('terminal:missing'))
    end)

    it('rejects unsupported views before starting the terminal job', function()
        local plugin = require('terminal_manager')

        local terminal = plugin.api.create({
            name = 'build',
        })

        assert.has_error(function()
            plugin.api.open(terminal.id, {
                view = 'bogus',
            })
        end, 'Unsupported terminal view: bogus')

        local current = assert(plugin.api.get(terminal.id))

        assert.is_nil(current.job_id)
        assert.are.equal('registered', current.status)
    end)

    it('rejects unsupported views before creating terminal records', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = true,
            state_file = state_file,
        })

        assert.has_error(function()
            plugin.api.create({
                name = 'build',
                view = 'bogus',
            })
        end, 'Unsupported terminal view: bogus')

        assert.has_error(function()
            plugin.api.create_and_open({
                name = 'build',
                view = 'bogus',
            })
        end, 'Unsupported terminal view: bogus')

        assert.are.same({}, plugin.api.list())
        assert.are.equal(0, vim.fn.filereadable(state_file))

        local terminal = plugin.api.create({
            name = 'build',
        })

        assert.are.equal('terminal:1', terminal.id)
    end)

    it('restarts an exited terminal in place when reopened', function()
        local plugin = require('terminal_manager')

        local terminal = plugin.api.create({
            name = 'echo',
            command = { 'sh', '-lc', 'printf ready; sleep 1' },
        })

        local opened = plugin.api.open(terminal.id)
        local first_bufnr = assert(opened.bufnr)

        vim.wait(2000, function()
            local current = assert(plugin.api.get(terminal.id))
            return current.status == 'exited'
        end, 20)

        local restarted = plugin.api.open(terminal.id)

        assert.are.equal('running', restarted.status)
        assert.is_true(assert(restarted.job_id) > 0)
        assert.are_not.equal(first_bufnr, restarted.bufnr)
        assert.is_nil(restarted.exit_code)
    end)

    it('keeps the previous exited buffer when restart startup fails', function()
        local plugin = require('terminal_manager')
        local original_termopen = vim.fn.termopen

        local terminal = plugin.api.create({
            name = 'echo',
            command = { 'sh', '-lc', 'printf first' },
        })

        plugin.api.start(terminal.id)
        plugin.api.wait(terminal.id, 2000)

        local exited = assert(plugin.api.get(terminal.id))
        local original_bufnr = assert(exited.bufnr)

        vim.fn.termopen = function()
            return 0
        end

        local ok, err = pcall(plugin.api.start, terminal.id)

        vim.fn.termopen = original_termopen

        assert.is_false(ok)
        assert.matches('Failed to start terminal ' .. terminal.id, err)

        local current = assert(plugin.api.get(terminal.id))
        assert.are.equal('exited', current.status)
        assert.are.equal(original_bufnr, current.bufnr)
        assert.is_true(vim.api.nvim_buf_is_valid(original_bufnr))
        assert.are.equal('first', plugin.api.output(terminal.id).output)
    end)

    it('preserves named lowercase marks when restarting an exited terminal in place', function()
        local plugin = require('terminal_manager')

        local terminal = plugin.api.create({
            name = 'echo',
            command = { 'sh', '-lc', 'printf ready; sleep 1' },
        })

        local opened = plugin.api.open(terminal.id)
        local bufnr = assert(opened.bufnr)

        vim.api.nvim_buf_set_mark(bufnr, 'a', 1, 0, {})

        vim.wait(2000, function()
            local current = assert(plugin.api.get(terminal.id))
            return current.status == 'exited'
        end, 20)

        local restarted = plugin.api.open(terminal.id)

        assert.are_not.equal(bufnr, restarted.bufnr)
        assert.are.same({ 1, 0 }, vim.api.nvim_buf_get_mark(assert(restarted.bufnr), 'a'))
    end)

    it('resets non-persistent live output when restarting an exited terminal', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = false,
            state_file = state_file,
        })

        local terminal = plugin.api.create({
            name = 'echo',
            command = { 'sh', '-lc', 'printf first' },
        })

        plugin.api.start(terminal.id)
        plugin.api.wait(terminal.id, 2000)
        assert.are.equal('first', plugin.api.output(terminal.id).output)

        plugin.api.update(terminal.id, {
            command = { 'sh', '-lc', 'printf second' },
        })
        plugin.api.open(terminal.id, { view = 'float' })
        plugin.api.wait(terminal.id, 2000)

        assert.are.equal('second', plugin.api.output(terminal.id).output)
    end)

    it('removes disposable terminals after exit', function()
        local plugin = require('terminal_manager')

        local terminal = plugin.api.create_and_open({
            name = 'scratch',
            command = { 'sh', '-lc', 'printf done' },
            disposable = true,
        })

        vim.wait(2000, function()
            return plugin.api.get(terminal.id) == nil
        end, 20)

        assert.is_nil(plugin.api.get(terminal.id))
        assert.are.same({}, plugin.api.list())
    end)

    it('does not report pruned disposables as exited before cleanup finishes', function()
        local plugin = require('terminal_manager')

        local terminal = plugin.api.create_and_open({
            name = 'scratch',
            command = { 'sh', '-lc', 'printf done' },
            disposable = true,
        })

        vim.wait(2000, function()
            return plugin.api.get(terminal.id) == nil
        end, 20)

        local exited = plugin.api.wait(terminal.id, 2000)

        assert.is_nil(exited)
    end)

    it('returns output for exited disposable terminals after registry pruning', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = false,
            state_file = state_file,
        })

        local terminal = plugin.api.create_and_open({
            name = 'scratch',
            command = { 'sh', '-lc', 'printf done' },
            disposable = true,
        })

        vim.wait(2000, function()
            return plugin.api.get(terminal.id) == nil
        end, 20)

        local output = plugin.api.output(terminal.id)

        assert.are.equal('done', output.output)
        assert.are.equal('exited', output.status)
        assert.are.equal(0, output.exit_code)
    end)

    it('opens history for exited disposable terminals after registry pruning', function()
        local plugin = require('terminal_manager')
        local uri = require('terminal_manager.uri')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = true,
            state_file = state_file,
        })

        local terminal = plugin.api.create_and_open({
            name = 'scratch',
            command = { 'sh', '-lc', 'printf done' },
            disposable = true,
        })

        vim.wait(2000, function()
            return plugin.api.get(terminal.id) == nil
        end, 20)

        plugin.api.open_history(terminal.id)

        local history_bufnr = vim.api.nvim_get_current_buf()

        assert.are.equal(uri.encode_history_uri(terminal), vim.api.nvim_buf_get_name(history_bufnr))
        assert.are.same({ 'done' }, vim.api.nvim_buf_get_lines(history_bufnr, 0, -1, false))
    end)

    it('falls back to the configured default view when restoring an unsupported persisted view', function()
        local plugin = require('terminal_manager')
        local history = require('terminal_manager.history')

        vim.fn.writefile({
            vim.json.encode({
                next_id = 2,
                terminals = {
                    {
                        id = 'terminal:1',
                        name = 'build',
                        namespace = 'workspace',
                        disposable = false,
                        cwd = vim.fn.getcwd(),
                        status = 'exited',
                        command = { 'sh', '-lc', 'printf done' },
                        view = 'bogus',
                        created_at = 1,
                        exit_code = 0,
                    },
                },
            }),
        }, state_file)

        history.append_chunks('terminal:1', { 'done', '' })
        history.flush('terminal:1')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            state_file = state_file,
            default_view = 'float',
        })

        local restored = assert(plugin.api.get('terminal:1'))

        assert.are.equal('float', restored.preferred_view)

        local opened = plugin.api.open('terminal:1')

        assert.are.equal('float', opened.preferred_view)
        assert.are.equal(assert(opened.bufnr), vim.api.nvim_get_current_buf())
    end)

    it('keeps never-started disposable terminals available when waiting', function()
        local plugin = require('terminal_manager')

        local terminal = plugin.api.create({
            name = 'scratch',
            command = { 'sh', '-lc', 'printf done' },
            disposable = true,
        })

        local waited = plugin.api.wait(terminal.id, 2000)

        assert.is_not_nil(waited)
        assert.are.equal(terminal.id, waited.id)
        assert.are.equal('registered', waited.status)
        assert.is_not_nil(plugin.api.get(terminal.id))

        plugin.api.open(terminal.id)
        local exited = plugin.api.wait(terminal.id, 2000)

        assert.is_not_nil(exited)
        assert.are.equal('exited', exited.status)
        assert.are.equal(0, exited.exit_code)
        assert.is_nil(plugin.api.get(terminal.id))
    end)

    it('preserves disposable history until cleanup is finalized', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = true,
            state_file = state_file,
        })

        local terminal = plugin.api.create_and_open({
            name = 'scratch',
            command = { 'sh', '-lc', 'printf done' },
            disposable = true,
        })

        local bufnr = assert(terminal.bufnr)

        local exited = plugin.api.wait(terminal.id, 2000)

        assert.is_not_nil(exited)
        assert.are.same({ 'done' }, plugin.api.history_lines(terminal.id))

        vim.cmd('close')
        vim.api.nvim_exec_autocmds('BufHidden', {
            buffer = bufnr,
            modeline = false,
        })
        local cleared = vim.wait(2000, function()
            return plugin.api.get(terminal.id) == nil
        end, 20)

        if cleared then
            assert.has_error(function()
                plugin.api.history_lines(terminal.id)
            end, 'Unknown terminal id: ' .. terminal.id)
        else
            assert.are.same({ 'done' }, plugin.api.history_lines(terminal.id))
        end
    end)

    it('does not finalize disposable cleanup for unrelated buffer events', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = true,
            state_file = state_file,
        })

        local terminal = plugin.api.create_and_open({
            name = 'scratch',
            command = { 'sh', '-lc', 'printf done' },
            disposable = true,
        })

        local bufnr = assert(terminal.bufnr)
        local other_bufnr = vim.api.nvim_create_buf(false, true)

        local exited = plugin.api.wait(terminal.id, 2000)

        assert.is_not_nil(exited)
        vim.api.nvim_exec_autocmds('BufHidden', {
            buffer = other_bufnr,
            modeline = false,
        })

        assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
        assert.are.same({ 'done' }, plugin.api.history_lines(terminal.id))
    end)

    it('keeps a visible disposable terminal buffer until the window closes', function()
        local plugin = require('terminal_manager')

        local terminal = plugin.api.create_and_open({
            name = 'scratch',
            command = { 'sh', '-lc', 'printf done' },
            disposable = true,
        })

        local bufnr = assert(terminal.bufnr)

        local exited = plugin.api.wait(terminal.id, 2000)

        assert.is_not_nil(exited)
        assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
        assert.is_true(#vim.fn.win_findbuf(bufnr) >= 1)

        vim.cmd('close')
        vim.wait(2000, function()
            return vim.api.nvim_buf_is_valid(bufnr) == false
        end, 20)
    end)

    it('preserves terminal buffer when hidden startup fails', function()
        local plugin = require('terminal_manager')
        local original_termopen = vim.fn.termopen
        local terminal

        local ok, err = xpcall(function()
            terminal = plugin.api.create({
                name = 'echo',
                command = { 'sh', '-lc', 'printf alive; sleep 0.1' },
            })

            local calls = 0

            vim.fn.termopen = function(command, opts)
                calls = calls + 1
                local job_id = original_termopen(command, opts)

                if calls == 1 then
                    error('simulated startup failure')
                end

                return job_id
            end

            local start_ok, start_err = pcall(plugin.api.start, terminal.id)

            assert.is_false(start_ok)
            assert.matches('simulated startup failure', start_err)

            local current = assert(plugin.api.get(terminal.id))
            local bufnr = assert(current.bufnr)
            assert.is_true(vim.api.nvim_buf_is_valid(bufnr))

            local listed = vim.fn.win_findbuf(bufnr)
            assert.are.same({}, listed)

            assert.are.equal('registered', assert(plugin.api.get(terminal.id)).status)
            plugin.api.release(terminal.id)
        end, debug.traceback)

        vim.fn.termopen = original_termopen

        if not ok then
            error(err)
        end
    end)

    it('keeps cleanup pending until the current disposable buffer loses focus', function()
        local plugin = require('terminal_manager')
        local runtime = require('terminal_manager.runtime.native')

        local terminal = plugin.api.create_and_open({
            name = 'scratch',
            command = { 'sh', '-lc', 'printf done' },
            disposable = true,
        })

        local bufnr = assert(terminal.bufnr)
        local exited = plugin.api.wait(terminal.id, 2000)

        assert.is_not_nil(exited)
        vim.api.nvim_exec_autocmds('BufHidden', {
            buffer = bufnr,
            modeline = false,
        })
        vim.wait(100, function()
            return false
        end, 20)

        assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
        assert.is_nil(plugin.api.get(terminal.id))
        assert.is_not_nil(runtime.exited_terminal(terminal.id))

        vim.cmd('enew')
        vim.wait(2000, function()
            return vim.api.nvim_buf_is_valid(bufnr) == false
        end, 20)
        vim.wait(2000, function()
            return runtime.exited_terminal(terminal.id) == nil
        end, 20)
    end)

    it('updates cwd metadata from OSC 7 terminal requests', function()
        local plugin = require('terminal_manager')
        local cwd = vim.fn.tempname()

        vim.fn.mkdir(cwd, 'p')

        local terminal = plugin.api.create({
            name = 'shell',
            command = { 'sh', '-lc', 'sleep 1' },
            cwd = '/tmp',
        })
        local opened = plugin.api.open(terminal.id)

        vim.api.nvim_exec_autocmds('TermRequest', {
            buffer = assert(opened.bufnr),
            data = {
                sequence = string.format('\027]7;file://%s\027\\', cwd),
                terminator = '\027\\',
                cursor = { 1, 1 },
            },
        })

        assert.are.equal(cwd, assert(plugin.api.get(terminal.id)).cwd)
    end)

    it('ignores OSC 7 requests for unmanaged buffers', function()
        local plugin = require('terminal_manager')
        local bufnr = vim.api.nvim_create_buf(false, true)
        local cwd = vim.fn.tempname()

        vim.fn.mkdir(cwd, 'p')

        plugin.api.create({
            name = 'shell',
            cwd = '/tmp',
        })

        vim.api.nvim_exec_autocmds('TermRequest', {
            buffer = bufnr,
            data = {
                sequence = string.format('\027]7;file://%s\027\\', cwd),
                terminator = '\027\\',
                cursor = { 1, 1 },
            },
        })

        assert.are.equal('/tmp', assert(plugin.api.get('terminal:1')).cwd)
    end)

    it('sanitizes terminal buffer names', function()
        local plugin = require('terminal_manager')
        local uri = require('terminal_manager.uri')
        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = true,
            state_file = state_file,
        })
        plugin.api.clear()
        local history = require('terminal_manager.history')

        local terminal = plugin.api.create({
            disposable = true,
            name = 'dir/name\001',
        })

        history.append_chunks(terminal.id, { 'ready', '' })
        history.flush(terminal.id)
        plugin.api.open_history(terminal.id)

        assert.are.equal(
            uri.encode_history_uri({
                id = terminal.id,
                name = terminal.name,
                context_id = terminal.context_id,
            }),
            vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
        )
    end)

    it('encodes and decodes canonical terminal uris with context stacks', function()
        local plugin = require('terminal_manager')
        local uri = require('terminal_manager.uri')
        local child = plugin.api.create_child_context(plugin.api.host_context().id, {
            kind = 'remote_workspace',
            label = 'devbox',
            metadata = {
                remote_workspace_id = 'workspace:devbox',
            },
        })
        local nested = plugin.api.create_child_context(child.id, {
            kind = 'devcontainer',
            label = 'app-dev',
            metadata = {
                config_path = '/tmp/devcontainer.json',
                devcontainer_id = 'devcontainer:app',
            },
        })
        local terminal = plugin.api.create({
            name = 'dir/name\001',
            context_id = nested.id,
        })

        local encoded = uri.encode_terminal_uri(terminal)
        local decoded = assert(uri.decode(encoded))

        assert.are.equal(encoded, string.format('%s', encoded))
        assert.are.equal('terminal', decoded.kind)
        assert.are.equal(terminal.id, decoded.terminal_id)
        assert.are.equal(terminal.name, decoded.name)
        assert.are.equal(nested.id, decoded.context_id)
        assert.are.same({ 'context:host', child.id, nested.id }, decoded.context_stack_ids)
        assert.are.equal('workspace:devbox', decoded.context_stack[2].metadata.remote_workspace_id)
        assert.are.equal('devcontainer:app', decoded.context_stack[3].metadata.devcontainer_id)
        assert.are.equal('/tmp/devcontainer.json', decoded.context_stack[3].metadata.config_path)
    end)

    it('reopens terminal-manager terminal uris and restores current context', function()
        local plugin = require('terminal_manager')
        local uri = require('terminal_manager.uri')
        local context = plugin.api.create_child_context(plugin.api.host_context().id, {
            kind = 'remote_workspace',
            label = 'devbox',
        })
        local terminal = plugin.api.create({
            name = 'build',
            command = { 'sh', '-lc', 'printf ready' },
            context_id = context.id,
        })

        plugin.api.clear_current_context()

        local reopened = plugin.api.open_uri(uri.encode_terminal_uri(terminal), {
            view = 'float',
        })

        assert.are.equal(terminal.id, reopened.id)
        assert.are.equal(context.id, plugin.api.current_context().id)
    end)

    it('reopens terminal-manager history uris and restores current context', function()
        local plugin = require('terminal_manager')
        local uri = require('terminal_manager.uri')
        local history = require('terminal_manager.history')
        local context = plugin.api.create_child_context(plugin.api.host_context().id, {
            kind = 'devcontainer',
            label = 'app-dev',
        })
        local terminal = plugin.api.create({
            name = 'build',
            context_id = context.id,
        })

        history.append_chunks(terminal.id, { 'alpha', '' })
        history.flush(terminal.id)
        plugin.api.clear_current_context()

        plugin.api.open_uri(uri.encode_history_uri(terminal))

        assert.are.equal(context.id, plugin.api.current_context().id)
        assert.are.equal(uri.encode_history_uri(terminal), vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
    end)

    it('reopens terminal-manager uris and reconstructs missing provider contexts', function()
        local plugin = require('terminal_manager')
        local uri = require('terminal_manager.uri')
        local contexts = require('terminal_manager.contexts')

        plugin.api.register_context_provider('fixture', {
            plan_command = function()
                error('unexpected plan_command use')
            end,
            restore_context = function(context_spec, parent_context)
                return plugin.api.create_child_context(parent_context.id, {
                    id = context_spec.id,
                    kind = context_spec.kind,
                    label = context_spec.label,
                    metadata = vim.deepcopy(context_spec.metadata or {}),
                })
            end,
        })

        local fixture = plugin.api.create_child_context(plugin.api.host_context().id, {
            kind = 'fixture',
            label = 'fixture-one',
            metadata = {
                fixture_id = 'fixture:one',
            },
        })
        local terminal = plugin.api.create({
            name = 'build',
            command = { 'sh', '-lc', 'printf ready' },
            context_id = fixture.id,
        })
        local encoded = uri.encode_terminal_uri(terminal)

        contexts.clear()
        assert.is_nil(plugin.api.get_context(fixture.id))

        local reopened = plugin.api.open_uri(encoded, {
            view = 'float',
        })

        assert.are.equal(terminal.id, reopened.id)
        assert.are.equal(fixture.id, plugin.api.current_context().id)
        assert.are.equal('fixture', plugin.api.current_context().kind)
        assert.are.equal('fixture:one', plugin.api.current_context().metadata.fixture_id)
    end)

    it('opens terminal uris through the user command surface', function()
        local plugin = require('terminal_manager')
        local uri = require('terminal_manager.uri')
        local terminal = plugin.api.create({
            name = 'build',
            command = { 'sh', '-lc', 'printf ready' },
        })

        vim.cmd(string.format('TerminalManagerOpenUri %s float', uri.encode_terminal_uri(terminal)))

        assert.are.equal(
            uri.encode_terminal_uri(terminal),
            vim.api.nvim_buf_get_name(assert(plugin.api.get(terminal.id)).bufnr)
        )
    end)

    it('rejects malformed terminal uris clearly', function()
        local uri = require('terminal_manager.uri')

        local decoded, err = uri.decode('terminal-manager://bogus')

        assert.is_nil(decoded)
        assert.are.equal('Malformed terminal-manager URI', err)
    end)

    it('rejects unknown terminal-manager uris through the api', function()
        local plugin = require('terminal_manager')

        assert.has_error(function()
            plugin.api.open_uri(
                'terminal-manager://terminal/contexts/host/Host/context:host/terminal/terminal:missing/build'
            )
        end, 'Unknown terminal id: terminal:missing')
    end)

    it('decodes context labels that contain the terminal marker literally', function()
        local plugin = require('terminal_manager')
        local uri = require('terminal_manager.uri')
        local context = plugin.api.create_child_context(plugin.api.host_context().id, {
            kind = 'fixture',
            label = 'terminal',
        })
        local terminal = plugin.api.create({
            name = 'build',
            context_id = context.id,
        })

        local decoded = assert(uri.decode(uri.encode_terminal_uri(terminal)))

        assert.are.equal('terminal', decoded.context_stack[2].label)
    end)

    it('completes cwd prefixes for quoted namespaces', function()
        local plugin = require('terminal_manager')
        local commands = vim.api.nvim_get_commands({})
        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            state_file = state_file,
        })
        plugin.api.clear()

        plugin.api.create({
            name = 'build',
            namespace = 'workspace team',
            cwd = '/tmp/workspace dir',
        })

        assert.are.same({
            '/tmp/workspace dir',
        }, commands.TerminalManagerList.complete('/tmp/w', [[TerminalManagerList "workspace team" /tmp/w]], 0))
    end)

    it('does not guess completion state from stray quote text', function()
        local plugin = require('terminal_manager')
        local commands = vim.api.nvim_get_commands({})

        plugin.api.create({
            name = 'build',
            namespace = 'workspace',
            cwd = '/tmp/workspace',
        })

        assert.are.same({}, commands.TerminalManagerList.complete('', [[TerminalManagerList workspace " ]], 0))
    end)

    it('treats Ex metacharacter prefixes as literal completion args', function()
        local plugin = require('terminal_manager')
        local commands = vim.api.nvim_get_commands({})

        plugin.api.create({
            name = 'build',
            namespace = '|workspace',
            cwd = '%/tmp/workspace',
        })

        assert.are.same({ '|workspace' }, commands.TerminalManagerList.complete('|', 'TerminalManagerList |', 0))
        assert.are.same(
            { '%/tmp/workspace' },
            commands.TerminalManagerList.complete('', 'TerminalManagerList |workspace ', 0)
        )
    end)
end)

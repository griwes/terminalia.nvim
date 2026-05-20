describe('terminalia', function()
    local history_dir
    local state_file

    ---@param opts? table
    local function setup_terminalia(opts)
        local plugin = require('terminalia')

        plugin.setup(vim.tbl_deep_extend('force', {
            history_dir = history_dir,
            notify_on_exit = false,
            state_file = state_file,
        }, opts or {}))

        return plugin
    end

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

    ---@param path string
    ---@return table
    local function read_json(path)
        return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
    end

    ---@param value string
    ---@return string
    local function encode_path_component(value)
        return value:gsub('[^%w._-]', function(char)
            return string.format('%%%02X', char:byte())
        end)
    end

    ---@param id string
    ---@return string
    local function record_filename(id)
        return string.format('%s.json', encode_path_component(id))
    end

    ---@param path string
    ---@param payload table
    local function write_json(path, payload)
        vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
        vim.fn.writefile({ vim.json.encode(payload) }, path)
    end

    ---@param terminal table
    ---@return table
    local function terminal_index_entry(terminal)
        return {
            id = terminal.id,
            name = terminal.name,
            namespace = terminal.namespace,
            cwd = terminal.cwd,
            context_id = terminal.context_id,
            status = terminal.status,
            file = record_filename(terminal.id),
        }
    end

    ---@param context table
    ---@return table
    local function context_index_entry(context)
        return {
            id = context.id,
            kind = context.kind,
            label = context.label,
            parent_id = context.parent_id,
            file = record_filename(context.id),
        }
    end

    ---@param path string
    ---@param payload table
    local function write_persisted_terminal_state(path, payload)
        local root = string.format('%s.d', path)
        local terminals = vim.tbl_filter(function(terminal)
            return type(terminal) == 'table' and type(terminal.id) == 'string'
        end, payload.terminals or {})
        local contexts = vim.tbl_filter(function(context)
            return type(context) == 'table' and type(context.id) == 'string'
        end, payload.contexts or {})

        for _, terminal in ipairs(terminals) do
            write_json(vim.fs.joinpath(root, 'terminals', record_filename(terminal.id)), terminal)
        end

        for _, context in ipairs(contexts) do
            write_json(vim.fs.joinpath(root, 'contexts', record_filename(context.id)), context)
        end

        write_json(path, {
            version = 1,
            next_id = payload.next_id,
            next_context_id = payload.next_context_id,
            current_context_id = payload.current_context_id,
            terminals = vim.tbl_map(terminal_index_entry, terminals),
            contexts = vim.tbl_map(context_index_entry, contexts),
        })
    end

    before_each(function()
        pcall(vim.cmd, 'silent! tabonly')
        pcall(vim.cmd, 'silent! only')

        history_dir = vim.fn.tempname()
        state_file = vim.fn.tempname()

        local plugin = setup_terminalia({
            persist_terminals = true,
        })
        plugin.api.clear()
    end)

    it('loads and exposes setup', function()
        local plugin = require('terminalia')

        assert.are.equal('function', type(plugin.setup))
        assert.are.equal('split', plugin.config.default_view)
    end)

    it('exposes the branded Overseer strategy module', function()
        assert.are.equal('function', type(require('overseer.strategy.terminalia_context').new))
    end)

    it('registers a session contributor when continuity.nvim is available', function()
        local observed = nil
        local original_session = package.loaded.continuity

        package.loaded.continuity = {
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
            setup_terminalia()
        end)

        package.loaded.continuity = original_session

        assert.is_true(ok, err)
        assert.are.equal('terminalia', assert(observed).name)
        assert.is_function(observed.contributor.capture)
        assert.is_function(observed.contributor.plan_restore)
        assert.is_function(observed.contributor.restore)
        assert.are.equal('after_layout', observed.contributor.restore_phase)
        assert.are.same({ 'arboretum', 'consulate', 'laboratory' }, observed.contributor.restore_after)
    end)

    it('captures Terminalia buffers for session contributors without requiring a visible window', function()
        local plugin = require('terminalia')
        local context = plugin.api.create_child_context(plugin.api.host_context().id, {
            kind = 'fixture',
            label = 'fixture',
        })

        plugin.api.set_current_context(context.id)

        local cwd = vim.fn.tempname()
        vim.fn.mkdir(cwd, 'p')
        local terminal = plugin.api.create_and_open({
            name = 'build',
            namespace = 'workspace',
            cwd = cwd,
            command = { 'sh', '-lc', 'printf ready' },
        })
        local terminal_buffer = assert(terminal.bufnr)
        local scratch = vim.api.nvim_create_buf(true, false)

        vim.api.nvim_win_set_buf(0, scratch)

        local captured = plugin.api.session_capture()

        assert.are.equal(0, #vim.fn.win_findbuf(terminal_buffer))
        assert.are.equal(context.id, captured.current_context_id)
        assert.are.equal(1, captured.version)
        assert.are.equal(state_file, captured.state_ref.state_file)
        assert.are.equal(1, #captured.terminal_ids)
        assert.are.equal(terminal.id, captured.terminal_ids[1])
        assert.is_nil(captured.terminals)

        local steps = plugin.api.session_plan_restore(captured)
        assert.are.equal(cwd, steps[1].payload.terminals[1].cwd)
        assert.are.equal(context.id, steps[1].payload.terminals[1].context_id)
        assert.is_true(vim.startswith(steps[1].payload.terminals[1].uri, 'terminalia://'))
    end)

    it('does not turn restored terminal metadata into Continuity restore payloads', function()
        local plugin = require('terminalia')

        plugin.api.create({
            name = 'metadata-only',
            namespace = 'workspace',
            cwd = '/tmp/workspace',
        })

        local captured = plugin.api.session_capture()
        local steps = plugin.api.session_plan_restore(captured)

        assert.are.equal(0, #captured.terminal_ids)
        assert.are.equal(0, #steps)
    end)

    it('builds restore-plan steps for terminal buffer records without window reopen semantics', function()
        local plugin = require('terminalia')

        write_persisted_terminal_state(state_file, {
            next_id = 2,
            next_context_id = 2,
            current_context_id = 'context:remote',
            terminals = {
                {
                    id = 'terminal:1',
                    uri = 'terminalia://terminal/terminal:1',
                    name = 'build',
                    namespace = 'workspace',
                    cwd = '/tmp/workspace',
                    context_id = 'context:remote',
                    preferred_view = 'float',
                    disposable = false,
                    status = 'running',
                },
            },
            contexts = {
                {
                    id = 'context:remote',
                    kind = 'fixture',
                    label = 'remote',
                    parent_id = 'context:host',
                },
            },
        })

        local steps = plugin.api.session_plan_restore({
            version = 1,
            current_context_id = 'context:remote',
            state_ref = {
                kind = 'terminalia.persistence',
                state_file = state_file,
            },
            terminal_ids = { 'terminal:1' },
        })

        assert.are.equal(1, #steps)
        assert.are.equal('terminalia.restore_terminal_buffers', steps[1].kind)
        assert.is_true(vim.startswith(steps[1].payload.terminals[1].uri, 'terminalia://terminal/'))
        assert.matches('terminal:1', steps[1].payload.terminals[1].uri, 1, true)
        assert.are.equal('/tmp/workspace', steps[1].payload.terminals[1].cwd)
    end)

    it('restores Terminalia session records without opening windows', function()
        local plugin = require('terminalia')
        local original_open_uri = plugin.api.open_uri
        local original_start = plugin.api.start

        plugin.api.open_uri = function(uri, opts)
            error(string.format('unexpected window open: %s %s', uri, vim.inspect(opts)))
        end
        plugin.api.start = function(id)
            error(string.format('unexpected terminal start: %s', id))
        end

        local restored = plugin.api.session_restore({
            kind = 'terminalia.restore_terminal_buffers',
            payload = {
                terminals = {
                    {
                        id = 'terminal:1',
                        uri = 'terminalia://terminal/terminal:1',
                        name = 'build',
                        namespace = 'workspace',
                        cwd = '/tmp/workspace',
                        context_id = 'context:host',
                        preferred_view = 'float',
                        disposable = false,
                        status = 'running',
                    },
                },
            },
        })

        plugin.api.open_uri = original_open_uri
        plugin.api.start = original_start

        assert.are.equal(1, #restored)
        assert.are.equal('terminal:1', restored[1].id)
        assert.are.equal('build', restored[1].name)
        assert.are.equal('/tmp/workspace', restored[1].cwd)
        assert.are.equal('registered', restored[1].status)
        assert.are.equal('float', restored[1].preferred_view)
    end)

    it('adopts and starts visible restored Terminalia URI buffers in place', function()
        local plugin = require('terminalia')
        local uri = require('terminalia.uri')
        local original_start = plugin.api.start
        local started = {}
        local terminal_uri = uri.encode_terminal_uri({
            id = 'terminal:visible',
            name = 'visible',
            context_id = 'context:host',
        })
        local bufnr = vim.api.nvim_create_buf(true, true)

        plugin.api.start = function(id)
            table.insert(started, id)
            return plugin.api.update(id, {
                status = 'running',
                job_id = 123,
            })
        end
        vim.api.nvim_buf_set_name(bufnr, terminal_uri)
        vim.api.nvim_win_set_buf(0, bufnr)

        local restored = plugin.api.session_restore({
            kind = 'terminalia.restore_terminal_buffers',
            payload = {
                terminals = {
                    {
                        id = 'terminal:visible',
                        uri = terminal_uri,
                        name = 'visible',
                        namespace = 'workspace',
                        cwd = '/tmp/workspace',
                        context_id = 'context:host',
                        preferred_view = 'split',
                        disposable = false,
                        status = 'running',
                    },
                },
            },
        })

        plugin.api.start = original_start

        assert.are.same({ 'terminal:visible' }, started)
        assert.are.equal(1, #restored)
        assert.are.equal(bufnr, restored[1].bufnr)
        assert.are.equal(bufnr, vim.api.nvim_win_get_buf(0))
        assert.are.equal('terminal:visible', vim.b[bufnr].terminalia_id)
        assert.are.equal('running', restored[1].status)
    end)

    it('adopts explicitly edited Terminalia live URI buffers in place', function()
        local plugin = require('terminalia')
        local uri = require('terminalia.uri')
        local original_start = plugin.api.start
        local started = {}
        local terminal = plugin.api.create({
            name = 'shell',
            command = { 'sh', '-lc', 'printf ready' },
        })
        local terminal_uri = uri.encode_terminal_uri(terminal)
        local winid = vim.api.nvim_get_current_win()

        plugin.api.start = function(id)
            table.insert(started, id)
            return plugin.api.update(id, {
                bufnr = vim.api.nvim_get_current_buf(),
                status = 'running',
                job_id = 321,
            })
        end

        vim.api.nvim_cmd({ cmd = 'edit', args = { terminal_uri } }, {})

        plugin.api.start = original_start

        local bufnr = vim.api.nvim_get_current_buf()
        local adopted = assert(plugin.api.get(terminal.id))

        assert.are.same({ terminal.id }, started)
        assert.are.equal(winid, vim.api.nvim_get_current_win())
        assert.are.equal(terminal_uri, vim.api.nvim_buf_get_name(bufnr))
        assert.are.equal(bufnr, adopted.bufnr)
        assert.are.equal('running', adopted.status)
        assert.are.equal(terminal.id, vim.b[bufnr].terminalia_id)
        assert.is_false(vim.bo[bufnr].swapfile)
    end)

    it('adopts explicitly edited Terminalia history URI buffers in place', function()
        local plugin = require('terminalia')
        local uri = require('terminalia.uri')
        local history = require('terminalia.history')
        local terminal = plugin.api.create({
            name = 'build',
        })
        local history_uri = uri.encode_history_uri(terminal)
        local winid = vim.api.nvim_get_current_win()
        local window_count = #vim.api.nvim_list_wins()

        history.append_chunks(terminal.id, { 'alpha', 'beta', '' })
        history.flush(terminal.id)

        vim.api.nvim_cmd({ cmd = 'edit', args = { history_uri } }, {})

        local bufnr = vim.api.nvim_get_current_buf()

        assert.are.equal(winid, vim.api.nvim_get_current_win())
        assert.are.equal(window_count, #vim.api.nvim_list_wins())
        assert.are.equal(history_uri, vim.api.nvim_buf_get_name(bufnr))
        assert.are.same({ 'alpha', 'beta' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
        assert.are.equal('nofile', vim.bo[bufnr].buftype)
        assert.are.equal('terminaliahistory', vim.bo[bufnr].filetype)
        assert.is_false(vim.bo[bufnr].swapfile)
        assert.is_false(vim.bo[bufnr].modified)
    end)

    it('notifies continuity.nvim when Terminalia state changes', function()
        local plugin = require('terminalia')
        local notified = {}
        local original_session = package.loaded.continuity

        package.loaded.continuity = {
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

        package.loaded.continuity = original_session

        assert.are.same({
            'terminalia',
            'terminalia',
            'terminalia',
            'terminalia',
            'terminalia',
        }, notified)
    end)

    it('uses the current and explicit overseer contexts separately', function()
        local plugin = require('terminalia')

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

        assert.are.equal(fixture.id, task.metadata.terminalia.context_id)
        assert.are.equal(fixture.id, task.metadata.fixture.context_id)

        local host = plugin.api.host_context()
        plugin.api.set_overseer_context(host.id)

        local overridden = plugin.api.build_overseer_task({ 'echo', 'two' })

        assert.are.equal(host.id, plugin.api.overseer_context().id)
        assert.are.equal(host.id, overridden.metadata.terminalia.context_id)

        plugin.api.clear_overseer_context()

        assert.are.equal(fixture.id, plugin.api.overseer_context().id)
    end)

    it('uses configured default namespace for new terminals', function()
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
        package.loaded['terminalia'] = nil
        local fresh_plugin = require('terminalia')

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

    it('restores persisted terminal metadata during setup without restarting jobs', function()
        local plugin = require('terminalia')

        plugin.api.create({
            name = 'build',
            namespace = 'workspace',
            cwd = '/tmp/workspace',
            env = {
                TERMINALIA_PERSIST_TEST = 'persisted',
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
        assert.are.same({ TERMINALIA_PERSIST_TEST = 'persisted' }, restored.env)
        assert.are.equal('registered', restored.status)
        assert.is_nil(restored.job_id)
        assert.is_nil(restored.bufnr)
    end)

    it('restores persisted terminal contexts and current context selection during setup', function()
        local plugin = require('terminalia')

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

    it('persists terminals and contexts as a compact index plus fragmented records', function()
        local plugin = require('terminalia')

        plugin.api.create_context({
            id = 'context:remote',
            kind = 'remote',
            label = 'Remote',
            parent_id = 'context:host',
            metadata = {
                host = 'devbox',
            },
        })
        plugin.api.create({
            name = 'build',
            namespace = 'workspace',
            context_id = 'context:remote',
            env = {
                KEEP = 'value',
            },
        })

        local index = read_json(state_file)
        local root = string.format('%s.d', state_file)
        local terminal = read_json(vim.fs.joinpath(root, 'terminals', 'terminal%3A1.json'))
        local context = read_json(vim.fs.joinpath(root, 'contexts', 'context%3Aremote.json'))

        assert.are.equal(1, index.version)
        assert.are.equal(1, #index.terminals)
        assert.are.equal('terminal%3A1.json', index.terminals[1].file)
        assert.is_nil(index.terminals[1].env)
        assert.are.equal('value', terminal.env.KEEP)
        assert.are.equal('devbox', context.metadata.host)
    end)

    it('reloads persisted terminals after clear resets setup persistence state', function()
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')
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
        local plugin = require('terminalia')
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
        local plugin = require('terminalia')
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
        local plugin = require('terminalia')
        local first_state_file = vim.fn.tempname()
        local second_state_file = vim.fn.tempname()

        write_persisted_terminal_state(second_state_file, {
            terminals = {
                {
                    id = 'terminal:1',
                    name = 'stale',
                    namespace = 'default',
                    disposable = false,
                    cwd = vim.fn.getcwd(),
                    status = 'registered',
                    view = 'split',
                    created_at = 1,
                },
            },
        })

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
        local plugin = require('terminalia')
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
        local plugin = require('terminalia')

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

        write_persisted_terminal_state(state_file, {
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
        })

        plugin.api.restore({
            force = true,
            merge = false,
        })

        assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
        assert.are.equal('restored', assert(plugin.api.get('terminal:1')).name)
    end)

    it('preserves destination persisted state when switching state files', function()
        local plugin = require('terminalia')
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
        local plugin = require('terminalia')
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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
                TERMINALIA_RUNTIME_TEST = 'old',
            },
            command = {
                'sh',
                '-lc',
                'printf "%s|%s" "$PWD" "$TERMINALIA_RUNTIME_TEST"',
            },
        })

        plugin.api.set_cwd(terminal.id, temp_dir)
        local updated = assert(plugin.api.get(terminal.id))
        updated.env = {
            TERMINALIA_RUNTIME_TEST = 'new',
        }

        plugin.api.start(terminal.id)
        plugin.api.wait(terminal.id, 2000)

        assert.are.equal(temp_dir .. '|new', plugin.api.output(terminal.id).output)
    end)

    it('captures terminal history durably and restores it across setup', function()
        local plugin = require('terminalia')

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

    it('includes live output fragments in history line snapshots before exit', function()
        local plugin = require('terminalia')

        local terminal = plugin.api.create({
            name = 'build',
            command = { 'sh', '-lc', 'printf "one\\ntwo"; sleep 1' },
        })

        plugin.api.open(terminal.id)

        vim.wait(1000, function()
            local snapshot = plugin.api.history_lines(terminal.id)
            return #snapshot >= 2
        end, 20)

        assert.are.same({ 'one', 'two' }, plugin.api.history_lines(terminal.id))
        assert.are.equal('one\ntwo', plugin.api.output(terminal.id).output)
    end)

    it('reconstructs partial history chunks across callback boundaries', function()
        local plugin = require('terminalia')
        local history = require('terminalia.history')

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')
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

        write_persisted_terminal_state(state_file, {
            next_id = 99,
            terminals = terminals,
        })

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')
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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')
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

        assert.is_truthy(commands.TerminaliaNew)
        assert.is_truthy(commands.TerminaliaOpen)
        assert.is_truthy(commands.TerminaliaList)
        assert.is_truthy(commands.TerminaliaHistory)
        assert.is_truthy(commands.TerminaliaExternalOpen)
    end)

    it('completes terminal ids for open and history commands', function()
        local plugin = require('terminalia')
        local terminal = plugin.api.create({
            name = 'build',
            namespace = 'workspace',
        })
        local commands = vim.api.nvim_get_commands({})

        assert.is_function(commands.TerminaliaOpen.complete)
        assert.is_function(commands.TerminaliaHistory.complete)
        assert.are.same({ terminal.id }, commands.TerminaliaOpen.complete('', 'TerminaliaOpen ', 0))
        assert.are.same({ terminal.id }, commands.TerminaliaHistory.complete('', 'TerminaliaHistory ', 0))
    end)

    it('completes namespaces, cwd prefixes, and view kinds for terminal commands', function()
        local plugin = require('terminalia')
        local terminal = plugin.api.create({
            name = 'build',
            namespace = 'workspace',
            cwd = '/tmp/workspace',
        })
        local commands = vim.api.nvim_get_commands({})

        assert.are.equal(terminal.id, plugin.api.list()[1].id)
        assert.are.same({ 'workspace' }, commands.TerminaliaNew.complete('w', 'TerminaliaNew build w', 0))
        assert.are.same({ 'split' }, commands.TerminaliaNew.complete('s', 'TerminaliaNew build workspace s', 0))
        assert.are.same({ 'float' }, commands.TerminaliaOpen.complete('f', 'TerminaliaOpen terminal:1 f', 0))
        assert.are.same({ 'workspace' }, commands.TerminaliaList.complete('w', 'TerminaliaList w', 0))
        assert.are.same(
            { '/tmp/workspace' },
            commands.TerminaliaList.complete('/tmp/w', 'TerminaliaList workspace /tmp/w', 0)
        )
        assert.are.same({}, commands.TerminaliaNew.complete('', 'TerminaliaNew build workspace split ', 0))
        assert.are.same({}, commands.TerminaliaOpen.complete('', 'TerminaliaOpen terminal:1 float ', 0))
        assert.are.same({}, commands.TerminaliaList.complete('', 'TerminaliaList workspace /tmp/workspace extra', 0))
    end)

    it('creates a terminal through the user command surface', function()
        local plugin = require('terminalia')

        plugin.setup({
            notify_on_exit = false,
            shell = { 'sh', '-lc', 'printf ready' },
            state_file = state_file,
        })

        vim.cmd('TerminaliaNew build workspace split')

        local items = plugin.api.list()

        assert.are.equal(1, #items)
        assert.are.equal('build', items[1].name)
        assert.are.equal('workspace', items[1].namespace)
        assert.are.equal('running', items[1].status)
    end)

    it('creates a terminal with quoted multi-word command arguments', function()
        local plugin = require('terminalia')

        plugin.setup({
            notify_on_exit = false,
            shell = { 'sh', '-lc', 'printf ready' },
            state_file = state_file,
        })

        vim.cmd([[TerminaliaNew "build task" "shared workspace" float]])

        local items = plugin.api.list()

        assert.are.equal(1, #items)
        assert.are.equal('build task', items[1].name)
        assert.are.equal('shared workspace', items[1].namespace)
        assert.are.equal('float', items[1].preferred_view)
    end)

    it('creates a terminal with escaped quotes inside quoted command arguments', function()
        local plugin = require('terminalia')

        plugin.setup({
            notify_on_exit = false,
            shell = { 'sh', '-lc', 'printf ready' },
            state_file = state_file,
        })

        vim.cmd([=[TerminaliaNew "build \"fast\" task" "shared \"quoted\" workspace" float]=])

        local items = plugin.api.list()

        assert.are.equal(1, #items)
        assert.are.equal('build "fast" task', items[1].name)
        assert.are.equal('shared "quoted" workspace', items[1].namespace)
        assert.are.equal('float', items[1].preferred_view)
    end)

    it('preserves literal backslashes inside quoted command arguments', function()
        local plugin = require('terminalia')

        plugin.setup({
            notify_on_exit = false,
            shell = { 'sh', '-lc', 'printf ready' },
            state_file = state_file,
        })

        vim.cmd([=[TerminaliaNew "C:\\tmp\\build" "shared\\workspace" float]=])

        local items = plugin.api.list()

        assert.are.equal(1, #items)
        assert.are.equal([[C:\\tmp\\build]], items[1].name)
        assert.are.equal([[shared\\workspace]], items[1].namespace)
        assert.are.equal('float', items[1].preferred_view)
    end)

    it('follows Neovim parsing for trailing backslashes inside quoted command arguments', function()
        local plugin = require('terminalia')

        plugin.setup({
            notify_on_exit = false,
            shell = { 'sh', '-lc', 'printf ready' },
            state_file = state_file,
        })

        vim.cmd([=[TerminaliaNew "C:\\tmp\\" "shared\\" float]=])

        local items = plugin.api.list()

        assert.are.equal(1, #items)
        assert.are.equal([[C:\\tmp\]], items[1].name)
        assert.are.equal([[shared\]], items[1].namespace)
        assert.are.equal('float', items[1].preferred_view)
    end)

    it('preserves even backslash runs before quotes inside quoted command arguments', function()
        local plugin = require('terminalia')

        plugin.setup({
            notify_on_exit = false,
            shell = { 'sh', '-lc', 'printf ready' },
            state_file = state_file,
        })

        vim.cmd([=[TerminaliaNew "C:\\\"" "shared\\\"" float]=])

        local items = plugin.api.list()

        assert.are.equal(1, #items)
        assert.are.equal([[C:\"]], items[1].name)
        assert.are.equal([[shared\"]], items[1].namespace)
        assert.are.equal('float', items[1].preferred_view)
    end)

    it('treats unterminated quoted command arguments as a single trailing argument', function()
        local plugin = require('terminalia')

        plugin.setup({
            notify_on_exit = false,
            shell = { 'sh', '-lc', 'printf ready' },
            state_file = state_file,
        })

        vim.cmd([[TerminaliaNew "build task workspace split]])

        local items = plugin.api.list()

        assert.are.equal(1, #items)
        assert.are.equal('build task workspace split', items[1].name)
        assert.are.equal(plugin.config.default_namespace, items[1].namespace)
        assert.are.equal(plugin.config.default_view, items[1].preferred_view)
    end)

    it('parses mixed quoted and unquoted command arguments with extra whitespace', function()
        local plugin = require('terminalia')

        plugin.setup({
            notify_on_exit = false,
            shell = { 'sh', '-lc', 'printf ready' },
            state_file = state_file,
        })

        vim.cmd([[TerminaliaNew   build   "shared workspace"   float]])

        local items = plugin.api.list()

        assert.are.equal(1, #items)
        assert.are.equal('build', items[1].name)
        assert.are.equal('shared workspace', items[1].namespace)
        assert.are.equal('float', items[1].preferred_view)
    end)

    it('opens a terminal buffer through the public api', function()
        local plugin = require('terminalia')

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

    it('renders Terminalia buffer winbars through Statuesque when it is available', function()
        local plugin = require('terminalia')
        local original_statuesque = package.loaded.statuesque
        local observed = {}
        local terminal = plugin.api.create({
            name = 'shell',
            command = { 'sh', '-lc', 'printf ready' },
            cwd = '/tmp/workspace',
        })
        local bufnr = vim.api.nvim_create_buf(true, false)

        package.loaded.statuesque = {
            replace_window_surface = function(opts)
                observed.replacement = opts
                vim.wo[0][opts.target] = opts.expression
                return { vim.api.nvim_get_current_win() }
            end,
            compose = function(spec, opts)
                observed.sigil = opts.sigil
                observed.surface = opts.surface
                return spec
            end,
            render = function(spec, target, opts)
                observed.target = target
                observed.winid = opts.winid
                observed.spec = spec
                return 'statuesque-terminalia-winbar'
            end,
        }

        vim.b[bufnr].terminalia_id = terminal.id
        vim.api.nvim_win_set_buf(0, bufnr)
        require('terminalia.winbar').install(bufnr)

        local rendered = require('terminalia.winbar').render()

        package.loaded.statuesque = original_statuesque

        assert.are.equal("%!v:lua.require'terminalia.winbar'.render()", vim.wo[0].winbar)
        assert.are.equal('statuesque-terminalia-winbar', rendered)
        assert.are.equal('terminalia', observed.replacement.owner)
        assert.are.equal('winbar', observed.replacement.target)
        assert.are.equal(bufnr, observed.replacement.bufnr)
        assert.is_true(observed.replacement.all_windows)
        assert.are.equal('', observed.sigil)
        assert.are.equal('winbar', observed.surface)
        assert.are.equal('winbar', observed.target)
        assert.are.equal(vim.api.nvim_get_current_win(), observed.winid)
        assert.are.equal('terminalia', observed.spec.left[1].role)
    end)

    it('starts terminals in terminal buffers', function()
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')
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
        assert.are.same({ 'ready' }, plugin.api.output_lines(terminal.id))
    end)

    it('returns live output even when history persistence is disabled', function()
        local plugin = require('terminalia')

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
        assert.are.same({ 'transient' }, plugin.api.output_lines(terminal.id))
        assert.are.equal('exited', assert(exited).status)
        vim.wait(2000, function()
            return #plugin.api.history_lines(terminal.id) == 1
        end, 20)
        assert.are.same({ 'transient' }, plugin.api.history_lines(terminal.id))
    end)

    it('passes request-scoped environment variables into the terminal job', function()
        local plugin = require('terminalia')

        local terminal = plugin.api.create({
            name = 'env',
            command = { 'sh', '-lc', 'printf "$TERMINALIA_TEST_VALUE"' },
            env = {
                TERMINALIA_TEST_VALUE = 'from-env',
            },
        })

        plugin.api.start(terminal.id)
        plugin.api.wait(terminal.id, 2000)

        assert.are.equal('from-env', plugin.api.output(terminal.id).output)
    end)

    it('preserves inherited environment when extending terminal env', function()
        local plugin = require('terminalia')
        local original_path = vim.env.PATH

        assert.is_truthy(original_path and original_path ~= '')

        local terminal = plugin.api.create({
            name = 'env-path',
            command = { 'sh', '-lc', 'printf "%s|%s" "$PATH" "$TERMINALIA_TEST_VALUE"' },
            env = {
                TERMINALIA_TEST_VALUE = 'from-env',
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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')
        local runtime = require('terminalia.runtime.native')

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
        local plugin = require('terminalia')
        local runtime = require('terminalia.runtime.native')

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

        write_persisted_terminal_state(state_file, {
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

        assert.are.same({
            'terminal:1  [default]  registered  /tmp/workspace  terminal:1',
        }, plugin.api.list_lines())
    end)

    it('filters listed terminals by namespace and cwd prefix', function()
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
            vim.cmd('TerminaliaList workspace /tmp/work')
        end)

        assert.is_true(ok, err)
        assert.are.same({
            'terminal:1  [workspace]  registered  /tmp/workspace  build',
        }, notifications)
    end)

    it('filters command-line listing by namespace and cwd prefix', function()
        local plugin = require('terminalia')

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
            vim.cmd('TerminaliaList workspace /tmp/workspace')
        end)

        assert.is_true(ok, err)
        assert.are.same({
            'terminal:1  [workspace]  registered  /tmp/workspace  build',
        }, notifications)
    end)

    it('filters quoted namespace listings the same as completion', function()
        local plugin = require('terminalia')

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
            vim.cmd([[TerminaliaList "workspace team" /tmp/work]])
        end)

        assert.is_true(ok, err)
        assert.are.same({
            'terminal:1  [workspace team]  registered  /tmp/workspace dir  build',
        }, notifications)
    end)

    it('filters quoted namespace listings with multiple spaces in namespace', function()
        local plugin = require('terminalia')

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
            vim.cmd([[TerminaliaList "team alpha beta" /tmp/x/pro]])
        end)

        assert.is_true(ok, err)
        assert.are.same({
            'terminal:1  [team alpha beta]  registered  /tmp/x/project  build',
        }, notifications)
    end)

    it('reports when command-line filters match no terminals', function()
        local plugin = require('terminalia')
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

        local ok, err = pcall(vim.cmd, 'TerminaliaList devcontainer /tmp/missing')

        vim.notify = original_notify

        assert.is_true(ok, err)
        assert.are.same({
            'No terminals matched the requested filters',
        }, notifications)
    end)

    it('opens transcript history through the user command surface', function()
        local plugin = require('terminalia')
        local uri = require('terminalia.uri')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = true,
            state_file = state_file,
        })
        local history = require('terminalia.history')

        local terminal = plugin.api.create({
            name = 'build',
        })

        history.append_chunks(terminal.id, { 'alpha', 'beta', '' })
        history.flush(terminal.id)

        assert.are.same({ 'alpha', 'beta' }, plugin.api.history_lines(terminal.id))

        vim.cmd(string.format('TerminaliaHistory %s', terminal.id))

        local history_bufnr = vim.api.nvim_get_current_buf()

        assert.are.equal(uri.encode_history_uri(terminal), vim.api.nvim_buf_get_name(history_bufnr))
        assert.are.same({ 'alpha', 'beta' }, vim.api.nvim_buf_get_lines(history_bufnr, 0, -1, false))
        assert.is_false(vim.wo.wrap)
        assert.is_false(vim.wo.number)
        assert.is_false(vim.wo.relativenumber)
        assert.are.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    it('encodes active terminal names when opening history', function()
        local plugin = require('terminalia')
        local uri = require('terminalia.uri')

        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = true,
            state_file = state_file,
        })
        local history = require('terminalia.history')

        local terminal = plugin.api.create({
            name = 'dir/name\001',
        })

        history.append_chunks(terminal.id, { 'alpha', '' })
        history.flush(terminal.id)

        plugin.api.open_history(terminal.id)

        assert.are.equal(uri.encode_history_uri(terminal), vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
    end)

    it('opens history with live output fragments before terminal exit', function()
        local plugin = require('terminalia')

        local terminal = plugin.api.create({
            name = 'build',
            command = { 'sh', '-lc', 'printf "alpha\\nbeta"; sleep 1' },
        })

        plugin.api.open(terminal.id)

        vim.wait(1000, function()
            return #plugin.api.history_lines(terminal.id) >= 2
        end, 20)

        plugin.api.open_history(terminal.id)

        assert.are.same({ 'alpha', 'beta' }, vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false))
    end)

    it('rejects unknown ids for history inspection', function()
        local plugin = require('terminalia')

        assert.has_error(function()
            plugin.api.open_history('terminal:missing')
        end, 'Unknown terminal id: terminal:missing')
    end)

    it('opens an empty history buffer without placeholder text', function()
        local plugin = require('terminalia')
        local uri = require('terminalia.uri')

        local terminal = plugin.api.create({
            name = 'empty',
        })

        plugin.api.open_history(terminal.id)

        local history_bufnr = vim.api.nvim_get_current_buf()

        assert.are.equal(uri.encode_history_uri(terminal), vim.api.nvim_buf_get_name(history_bufnr))
        assert.are.same({ '' }, vim.api.nvim_buf_get_lines(history_bufnr, 0, -1, false))
    end)

    it('rejects unknown ids for history line reads', function()
        local plugin = require('terminalia')

        assert.has_error(function()
            plugin.api.history_lines('terminal:missing')
        end, 'Unknown terminal id: terminal:missing')
    end)

    it('returns nil when deleting an unknown terminal id', function()
        local plugin = require('terminalia')

        assert.is_nil(plugin.api.delete('terminal:missing'))
    end)

    it('rejects unsupported views before starting the terminal job', function()
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')
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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')
        local uri = require('terminalia.uri')

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
        local plugin = require('terminalia')
        local history = require('terminalia.history')

        write_persisted_terminal_state(state_file, {
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
        })

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')

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
        local plugin = require('terminalia')
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
        local plugin = require('terminalia')
        local runtime = require('terminalia.runtime.native')

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
        local plugin = require('terminalia')
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
        local plugin = require('terminalia')
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

    it('updates cwd metadata from shell-output fallback markers', function()
        local plugin = require('terminalia')
        local runtime = require('terminalia.runtime.native')
        local cwd = vim.fn.tempname()

        vim.fn.mkdir(cwd, 'p')

        local terminal = plugin.api.create({
            name = 'shell',
            cwd = '/tmp',
        })

        runtime._apply_cwd_fallback_chunks(terminal.id, {
            '__TERMINALIA_CWD__=' .. cwd,
            'plain output',
        })

        assert.are.equal(cwd, assert(plugin.api.get(terminal.id)).cwd)
    end)

    it('strips terminal line endings from shell-output cwd fallback markers', function()
        local plugin = require('terminalia')
        local runtime = require('terminalia.runtime.native')
        local cwd = vim.fn.tempname()

        vim.fn.mkdir(cwd, 'p')

        local terminal = plugin.api.create({
            name = 'shell',
            cwd = '/tmp',
        })

        runtime._apply_cwd_fallback_chunks(terminal.id, {
            '__TERMINALIA_CWD__=' .. cwd .. '\r',
        })

        assert.are.equal(cwd, assert(plugin.api.get(terminal.id)).cwd)
    end)

    it('strips shell-output cwd fallback markers when prompt output shares the chunk', function()
        local plugin = require('terminalia')
        local runtime = require('terminalia.runtime.native')
        local cwd = vim.fn.tempname()

        vim.fn.mkdir(cwd, 'p')

        local terminal = plugin.api.create({
            name = 'shell',
            cwd = '/tmp',
        })

        runtime._apply_cwd_fallback_chunks(terminal.id, {
            '__TERMINALIA_CWD__=' .. cwd .. '\r\nprompt',
        })

        local stripped = runtime._strip_cwd_fallback_chunks({
            '__TERMINALIA_CWD__=' .. cwd .. '\r\nprompt',
        })

        assert.are.equal(cwd, assert(plugin.api.get(terminal.id)).cwd)
        assert.are.same({ 'prompt' }, stripped)
    end)

    it('ignores invalid shell-output cwd fallback markers', function()
        local plugin = require('terminalia')
        local runtime = require('terminalia.runtime.native')

        local terminal = plugin.api.create({
            name = 'shell',
            cwd = '/tmp',
        })

        runtime._apply_cwd_fallback_chunks(terminal.id, {
            '__TERMINALIA_CWD__=/definitely/missing/terminalia/path',
            'plain output',
        })

        assert.are.equal('/tmp', assert(plugin.api.get(terminal.id)).cwd)
    end)

    it('wraps supported shell launches with cwd fallback marker emission', function()
        local plugin = require('terminalia')
        local runtime = require('terminalia.runtime.native')
        plugin.setup({
            emit_cwd_fallback_marker = true,
        })
        local resolved = runtime._resolve_command_with_fallback({ 'sh', '-lc', 'echo ready' })

        assert.are.same('sh', resolved[1])
        assert.are.same('-lc', resolved[2])
        assert.is_true(type(resolved[3]) == 'string' and resolved[3]:find('__TERMINALIA_CWD__=', 1, true) ~= nil)
        assert.is_true(type(resolved[3]) == 'string' and resolved[3]:find('echo ready', 1, true) ~= nil)
    end)

    it('does not wrap unsupported commands with cwd fallback marker emission', function()
        local runtime = require('terminalia.runtime.native')
        local command = { 'python3', '-c', 'print("ready")' }
        local resolved = runtime._resolve_command_with_fallback(command)

        assert.are.same(command, resolved)
    end)

    it('sanitizes terminal buffer names', function()
        local plugin = require('terminalia')
        local uri = require('terminalia.uri')
        plugin.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_history = true,
            state_file = state_file,
        })
        plugin.api.clear()
        local history = require('terminalia.history')

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
        local plugin = require('terminalia')
        local uri = require('terminalia.uri')
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
                config_path = '/tmp/laboratory.json',
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
        assert.are.equal('/tmp/laboratory.json', decoded.context_stack[3].metadata.config_path)
    end)

    it('reopens Terminalia terminal uris and restores current context', function()
        local plugin = require('terminalia')
        local uri = require('terminalia.uri')
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

    it('reopens Terminalia history uris and restores current context', function()
        local plugin = require('terminalia')
        local uri = require('terminalia.uri')
        local history = require('terminalia.history')
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

    it('reopens Terminalia uris and reconstructs missing provider contexts', function()
        local plugin = require('terminalia')
        local uri = require('terminalia.uri')
        local contexts = require('terminalia.context.state')

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
        local plugin = require('terminalia')
        local uri = require('terminalia.uri')
        local terminal = plugin.api.create({
            name = 'build',
            command = { 'sh', '-lc', 'printf ready' },
        })

        vim.cmd(string.format('TerminaliaOpenUri %s float', uri.encode_terminal_uri(terminal)))

        assert.are.equal(
            uri.encode_terminal_uri(terminal),
            vim.api.nvim_buf_get_name(assert(plugin.api.get(terminal.id)).bufnr)
        )
    end)

    it('rejects malformed terminal uris clearly', function()
        local uri = require('terminalia.uri')

        local decoded, err = uri.decode('terminalia://bogus')

        assert.is_nil(decoded)
        assert.are.equal('Malformed Terminalia URI', err)
    end)

    it('rejects unknown Terminalia uris through the api', function()
        local plugin = require('terminalia')

        assert.has_error(function()
            plugin.api.open_uri('terminalia://terminal/contexts/host/Host/context:host/terminal/terminal:missing/build')
        end, 'Unknown terminal id: terminal:missing')
    end)

    it('decodes context labels that contain the terminal marker literally', function()
        local plugin = require('terminalia')
        local uri = require('terminalia.uri')
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
        local plugin = require('terminalia')
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
        }, commands.TerminaliaList.complete('/tmp/w', [[TerminaliaList "workspace team" /tmp/w]], 0))
    end)

    it('does not guess completion state from stray quote text', function()
        local plugin = require('terminalia')
        local commands = vim.api.nvim_get_commands({})

        plugin.api.create({
            name = 'build',
            namespace = 'workspace',
            cwd = '/tmp/workspace',
        })

        assert.are.same({}, commands.TerminaliaList.complete('', [[TerminaliaList workspace " ]], 0))
    end)

    it('treats Ex metacharacter prefixes as literal completion args', function()
        local plugin = require('terminalia')
        local commands = vim.api.nvim_get_commands({})

        plugin.api.create({
            name = 'build',
            namespace = '|workspace',
            cwd = '%/tmp/workspace',
        })

        assert.are.same({ '|workspace' }, commands.TerminaliaList.complete('|', 'TerminaliaList |', 0))
        assert.are.same({ '%/tmp/workspace' }, commands.TerminaliaList.complete('', 'TerminaliaList |workspace ', 0))
    end)
end)

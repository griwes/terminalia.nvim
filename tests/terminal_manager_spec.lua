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
            state_file = state_file,
        })
        plugin.api.clear()
    end)

    it('loads and exposes setup', function()
        local plugin = require('terminal_manager')

        assert.are.equal('function', type(plugin.setup))
        assert.are.equal('split', plugin.config.default_view)
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
        assert.are.same({ terminal }, plugin.api.list())
    end)

    it('restores persisted terminal metadata during setup without restarting jobs', function()
        local plugin = require('terminal_manager')

        plugin.api.create({
            name = 'build',
            namespace = 'workspace',
            cwd = '/tmp/workspace',
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
        assert.are.equal('registered', restored.status)
        assert.is_nil(restored.job_id)
        assert.is_nil(restored.bufnr)
    end)

    it('captures terminal history durably and restores it across setup', function()
        local plugin = require('terminal_manager')

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
        local history = require('terminal_manager.history')

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

    it('reconciles restored terminal IDs and ignores malformed terminal IDs', function()
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
        assert.are.equal('terminal:4', restored_new.id)
        assert.are.equal('build', assert(plugin.api.get('terminal:1')).name)
        assert.is_nil(plugin.api.get('terminal:bogus'))
        assert.is_nil(plugin.api.get('7'))
    end)

    it('removes disposable terminal history during cleanup', function()
        local plugin = require('terminal_manager')

        local terminal = plugin.api.create_and_open({
            name = 'scratch',
            command = { 'sh', '-lc', 'printf done' },
            disposable = true,
        })

        vim.wait(2000, function()
            return plugin.api.get(terminal.id) == nil
        end, 20)

        assert.are.same({}, plugin.api.history_lines(terminal.id))
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

    it('registers user commands on plugin load', function()
        local commands = vim.api.nvim_get_commands({})

        assert.is_truthy(commands.TerminalManagerNew)
        assert.is_truthy(commands.TerminalManagerOpen)
        assert.is_truthy(commands.TerminalManagerList)
        assert.is_truthy(commands.TerminalManagerHistory)
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

    it('starts a terminal without opening a view and returns captured output', function()
        local plugin = require('terminal_manager')

        local terminal = plugin.api.create({
            name = 'echo',
            command = { 'sh', '-lc', 'printf ready' },
        })

        plugin.api.start(terminal.id)
        local exited = plugin.api.wait(terminal.id, 2000)
        local output = plugin.api.output(terminal.id)

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
        local history = require('terminal_manager.history')

        local terminal = plugin.api.create({
            name = 'build',
        })

        history.append_chunks(terminal.id, { 'alpha', 'beta', '' })
        history.flush(terminal.id)

        assert.are.same({ 'alpha', 'beta' }, plugin.api.history_lines(terminal.id))

        vim.cmd(string.format('TerminalManagerHistory %s', terminal.id))

        local history_bufnr = vim.api.nvim_get_current_buf()

        assert.are.equal(
            string.format('terminal-manager-history://%s/%s', terminal.id, terminal.name),
            vim.api.nvim_buf_get_name(history_bufnr)
        )
        assert.are.same({ 'alpha', 'beta' }, vim.api.nvim_buf_get_lines(history_bufnr, 0, -1, false))
    end)

    it('rejects unknown ids for history inspection', function()
        local plugin = require('terminal_manager')

        assert.has_error(function()
            plugin.api.open_history('terminal:missing')
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

        plugin.api.open(terminal.id)
        plugin.api.wait(terminal.id, 2000)

        assert.are.equal('first', plugin.api.output(terminal.id).output)
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
end)

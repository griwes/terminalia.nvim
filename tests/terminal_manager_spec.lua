describe('terminal_manager', function()
    before_each(function()
        local plugin = require('terminal_manager')

        plugin.setup({
            notify_on_exit = false,
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

    it('registers user commands on plugin load', function()
        local commands = vim.api.nvim_get_commands({})

        assert.is_truthy(commands.TerminalManagerNew)
        assert.is_truthy(commands.TerminalManagerOpen)
        assert.is_truthy(commands.TerminalManagerList)
    end)

    it('creates a terminal through the user command surface', function()
        local plugin = require('terminal_manager')

        plugin.setup({
            notify_on_exit = false,
            shell = { 'sh', '-lc', 'printf ready' },
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

    it('formats registered terminals for listing', function()
        local plugin = require('terminal_manager')

        plugin.api.create({
            name = 'build',
            namespace = 'workspace',
        })

        assert.are.same({
            'terminal:1  [workspace]  registered  build',
        }, plugin.api.list_lines())
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
end)

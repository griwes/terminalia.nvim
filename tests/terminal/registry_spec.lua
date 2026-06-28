describe('terminalia terminal registry', function()
    local history_dir
    local state_file

    before_each(function()
        local plugin = require('terminalia')
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

    it('rejects terminal ids with path separators', function()
        local plugin = require('terminalia')

        assert.has_error(function()
            plugin.api.create({
                id = '../escape',
                name = 'bad',
            })
        end, 'Invalid terminal id: "../escape"')
    end)

    it('creates an in-memory terminal record through the public api', function()
        local plugin = require('terminalia')

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

    it('binds created terminals to the current terminal context', function()
        local plugin = require('terminalia')

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

    it('rejects terminals created with unknown context ids', function()
        local plugin = require('terminalia')

        assert.has_error(function()
            plugin.api.create({
                name = 'orphan',
                context_id = 'context:missing',
            })
        end, 'Unknown terminal context id: "context:missing"')
    end)
end)

describe('terminalia context state', function()
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

    it('tracks a current host context by default', function()
        local plugin = require('terminalia')

        local current = plugin.api.current_context()
        local listed = plugin.api.list_contexts()

        assert.are.equal('context:host', current.id)
        assert.are.equal('host', current.kind)
        assert.are.equal('Host', current.label)
        assert.are.equal(1, #listed)
        assert.are.equal('context:host', listed[1].id)
    end)

    it('creates child terminal contexts and can set the current context', function()
        local plugin = require('terminalia')

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

    it('advances automatic context ids after creating an explicit numeric context id', function()
        local plugin = require('terminalia')

        plugin.api.create_context({
            id = 'context:1',
            label = 'manual',
        })

        local context = plugin.api.create_context({
            label = 'automatic',
        })

        assert.are.equal('context:2', context.id)
    end)
end)

describe('terminalia ministry integration', function()
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

    it(
        'derives Ministry terminal attachments from a terminal-owned context instead of the ambient current context',
        function()
            local plugin = require('terminalia')
            local original_ministry = package.loaded.ministry
            local provider = nil

            package.loaded.ministry = {
                register_list_item_data_provider = function(list_name, owner, callback)
                    provider = {
                        list_name = list_name,
                        owner = owner,
                        callback = callback,
                    }
                    return {
                        list_name = list_name,
                        owner = owner,
                        registered = true,
                    },
                        nil
                end,
            }

            local remote = plugin.api.create_child_context(plugin.api.host_context().id, {
                kind = 'remote_workspace',
                label = 'Devbox',
            })
            local nested = plugin.api.create_child_context(remote.id, {
                kind = 'devcontainer',
                label = 'app',
            })
            local terminal = plugin.api.create({
                name = 'shell',
                context_id = nested.id,
            })

            plugin.api.clear_current_context()
            local result, err = plugin.api.attach_ministry_terminal_context('ministry-term-1', terminal.id)
            plugin.api.update(terminal.id, {
                context_id = remote.id,
            })
            local attached = assert(provider).callback({
                terminal_id = 'ministry-term-1',
            }, 'ministry-term-1')

            package.loaded.ministry = original_ministry

            assert.is_nil(err)
            assert.are.same({
                list_name = 'terminals',
                item_id = 'ministry-term-1',
                owner = 'terminalia',
                attached = true,
            }, result)
            assert.are.same({
                list_name = 'terminals',
                owner = 'terminalia',
                callback = provider.callback,
            }, provider)
            assert.are.same({
                terminalia_context_stack = {
                    { id = 'context:host', kind = 'host', label = 'Host' },
                    { id = remote.id, kind = 'remote_workspace', label = 'Devbox' },
                },
            }, attached)
            assert.are.same(attached.terminalia_context_stack, plugin.api.context_stack_for_terminal(terminal.id))
        end
    )
end)

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
            local registrations = 0

            package.loaded.ministry = {
                register_list_item_data_provider = function(list_name, owner, callback)
                    registrations = registrations + 1
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
            local second_terminal = plugin.api.create({
                name = 'logs',
                context_id = remote.id,
            })

            plugin.api.clear_current_context()
            local result, err = plugin.api.attach_ministry_terminal_context('ministry-term-1', terminal.id)
            local second_result, second_err =
                plugin.api.attach_ministry_terminal_context('ministry-term-2', second_terminal.id)
            plugin.api.update(terminal.id, {
                context_id = remote.id,
            })
            local attached = assert(provider).callback({
                terminal_id = 'ministry-term-1',
            }, 'ministry-term-1')

            package.loaded.ministry = original_ministry

            assert.is_nil(err)
            assert.is_nil(second_err)
            assert.are.equal(1, registrations)
            assert.are.same({
                list_name = 'terminals',
                item_id = 'ministry-term-1',
                owner = 'terminalia',
                attached = true,
            }, result)
            assert.are.same({
                list_name = 'terminals',
                item_id = 'ministry-term-2',
                owner = 'terminalia',
                attached = true,
            }, second_result)
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

    it('drops Ministry terminal bindings when the mapped Terminalia terminal is deleted', function()
        local plugin = require('terminalia')
        local original_ministry = package.loaded.ministry
        local provider = nil

        package.loaded.ministry = {
            register_list_item_data_provider = function(_, _, callback)
                provider = callback
                return {
                    list_name = 'terminals',
                    owner = 'terminalia',
                },
                    nil
            end,
        }

        local remote = plugin.api.create_child_context(plugin.api.host_context().id, {
            kind = 'remote_workspace',
            label = 'Devbox',
        })
        local terminal = plugin.api.create({
            name = 'shell',
            context_id = remote.id,
        })

        local _, err = plugin.api.attach_ministry_terminal_context('ministry-term-1', terminal.id)
        plugin.api.delete(terminal.id)
        plugin.api.create({
            id = terminal.id,
            name = 'replacement',
            context_id = remote.id,
        })

        local attached = assert(provider)({
            terminal_id = 'ministry-term-1',
        })

        package.loaded.ministry = original_ministry

        assert.is_nil(err)
        assert.is_nil(attached)
    end)
end)

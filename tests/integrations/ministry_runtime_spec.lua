local ministry_root = vim.fs.normalize(vim.fs.joinpath(vim.fn.getcwd(), '..', 'ministry.nvim'))
vim.opt.runtimepath:prepend(ministry_root)

describe('terminalia ministry runtime integration', function()
    local history_dir
    local state_file

    before_each(function()
        local ministry = require('ministry')
        local terminalia = require('terminalia')

        ministry.reset()
        history_dir = vim.fn.tempname()
        state_file = vim.fn.tempname()
        terminalia.setup({
            history_dir = history_dir,
            notify_on_exit = false,
            persist_terminals = true,
            state_file = state_file,
        })
        terminalia.api.clear()
        ministry.setup({
            auto_start = false,
            enable_terminal_tools = true,
            approval = {
                enabled = false,
            },
        })
    end)

    it('adds the creation-time Terminalia context stack to real terminal list entries', function()
        local ministry = require('ministry')
        local terminalia = require('terminalia')
        local remote = terminalia.api.create_child_context(terminalia.api.host_context().id, {
            kind = 'remote_workspace',
            label = 'Devbox',
        })
        local nested = terminalia.api.create_child_context(remote.id, {
            kind = 'devcontainer',
            label = 'app',
        })

        terminalia.api.set_current_context(nested.id)
        local created, create_err = ministry.call_tool('neovim/terminal/create', {
            command = { 'printf', 'hello' },
        }, {})
        terminalia.api.clear_current_context()

        assert.is_nil(create_err)
        assert.is_not_nil(created)

        local read = ministry.handle_request('resources/read', {
            uri = 'neovim/terminals://list',
        }, 1, {})
        local payload = vim.json.decode(read.result.contents[1].text)
        local listed = nil
        for _, item in ipairs(payload.terminals) do
            if item.terminal_id == created.terminal_id then
                listed = item
                break
            end
        end

        assert.is_nil(read.error)
        assert.is_not_nil(listed)
        assert.are.same({
            { id = 'context:host', kind = 'host', label = 'Host' },
            { id = remote.id, kind = 'remote_workspace', label = 'Devbox' },
            { id = nested.id, kind = 'devcontainer', label = 'app' },
        }, listed.terminalia_context_stack)

        local _, release_err = ministry.call_tool('neovim/terminal/release', {
            terminal_id = created.terminal_id,
        }, {})
        assert.is_nil(release_err)
    end)
end)

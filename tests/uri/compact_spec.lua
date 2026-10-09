local contexts = require('terminalia.context.state')
local uri = require('terminalia.uri')

describe('terminalia.uri compact format', function()
    before_each(function()
        contexts.clear()
    end)

    after_each(function()
        contexts.clear()
    end)

    it('makes the host implicit and omits the default name', function()
        local terminal = { id = 'terminal:1', name = 'terminal:1', context_id = contexts.host().id }

        assert.are.equal('terminalia://1', uri.encode_terminal_uri(terminal))
        assert.are.equal('terminalia://1/history', uri.encode_history_uri(terminal))

        local decoded = assert(uri.decode('terminalia://1'))
        assert.are.equal(terminal.id, decoded.terminal_id)
        assert.are.equal(terminal.name, decoded.name)
        assert.are.equal('terminal', decoded.kind)
        assert.are.same({ 'context:host' }, decoded.context_stack_ids)
    end)

    it('retains explicit names without ambiguous path segments', function()
        local terminal = { id = 'terminal:1', name = 'history/contexts;build?#', context_id = contexts.host().id }
        local encoded = uri.encode_terminal_uri(terminal)

        assert.are.equal('terminalia://1?name=history%2Fcontexts%3Bbuild%3F%23', encoded)
        assert.are.equal(terminal.name, assert(uri.decode(encoded)).name)
        assert.are.equal('history', assert(uri.decode(uri.encode_history_uri(terminal))).kind)
    end)

    it('preserves an explicitly empty name', function()
        local terminal = { id = 'terminal:1', name = '' }
        assert.are.equal('terminalia://1?name=', uri.encode_terminal_uri(terminal))
        assert.are.equal('', assert(uri.decode(uri.encode_terminal_uri(terminal))).name)
    end)

    it('distinguishes terminal ids from history views and raw ids', function()
        for _, id in ipairs({ 'terminal:history', 'terminal:terminal', 'terminal:contexts', '1', 'history' }) do
            local terminal = { id = id, name = id }
            local live = assert(uri.decode(uri.encode_terminal_uri(terminal)))
            local history = assert(uri.decode(uri.encode_history_uri(terminal)))

            assert.are.equal('terminal', live.kind)
            assert.are.equal('history', history.kind)
            assert.are.equal(id, live.terminal_id)
            assert.are.equal(id, history.terminal_id)
        end
    end)

    it('carries nested provider contexts without emitting the host', function()
        local remote = contexts.create_child(contexts.host().id, {
            kind = 'remote_workspace',
            label = 'devbox',
            metadata = { remote_workspace_id = 'workspace:devbox' },
        })
        local container = contexts.create_child(remote.id, {
            kind = 'devcontainer',
            label = 'app-dev',
            metadata = { config_path = '/tmp/config;one.json', devcontainer_id = 'devcontainer:app' },
        })
        local terminal = { id = 'terminal:1', name = 'terminal:1', context_id = container.id }
        local encoded = uri.encode_terminal_uri(terminal)

        assert.are.equal(
            'terminalia://remote_workspace:1;label=devbox;meta.remote_workspace_id=workspace%3Adevbox/'
                .. 'devcontainer:2;label=app-dev;meta.config_path=%2Ftmp%2Fconfig%3Bone.json;meta.devcontainer_id=devcontainer%3Aapp/1',
            encoded
        )
        assert.is_nil(encoded:find('host', 1, true))
        contexts.clear()
        local decoded = assert(uri.decode(encoded))

        assert.are.same({ 'context:host', remote.id, container.id }, decoded.context_stack_ids)
        assert.are.equal('devbox', decoded.context_stack[2].label)
        assert.are.equal('workspace:devbox', decoded.context_stack[2].metadata.remote_workspace_id)
        assert.are.equal('/tmp/config;one.json', decoded.context_stack[3].metadata.config_path)
    end)

    it('keeps metadata keys separate from context labels', function()
        local context = contexts.create_child(contexts.host().id, {
            id = 'fixture',
            kind = 'terminal:custom',
            label = 'terminal',
            metadata = { label = 'metadata label', ['a;b=c'] = 'one/two', enabled = false, number = 12 },
        })
        local terminal = { id = 'terminal:1', name = 'terminal:1', context_id = context.id }
        local decoded = assert(uri.decode(uri.encode_terminal_uri(terminal)))
        local restored = decoded.context_stack[2]

        assert.are.equal(context.id, restored.id)
        assert.are.equal(context.kind, restored.kind)
        assert.are.equal(context.label, restored.label)
        assert.are.equal('metadata label', restored.metadata.label)
        assert.are.equal('one/two', restored.metadata['a;b=c'])
        assert.are.equal('false', restored.metadata.enabled)
        assert.are.equal('12', restored.metadata.number)
    end)

    it('rejects ambiguous or malformed compact paths', function()
        for _, body in ipairs({
            '',
            '/1',
            '1/',
            '1//history',
            '1%2Fescape',
            '@',
            '1%',
            '1%zz',
            '1#history',
            '1?unknown=value',
            '1?name=a&name=b',
            '1?name=a?name=b',
            'host:host/1',
            'fixture:1;label=one;label=two/1',
            'fixture:1;broken/1',
            'fixture:1;other=value/1',
            'fixture:1;meta.a=one;meta.%61=two/1',
            'fixture:1/fixture:1/1',
        }) do
            local decoded = uri.decode('terminalia://' .. body)
            assert.is_nil(decoded, body)
        end
    end)
end)

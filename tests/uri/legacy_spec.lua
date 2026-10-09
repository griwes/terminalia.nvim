local uri = require('terminalia.uri')

describe('terminalia.uri legacy formats', function()
    it('reads the previously emitted host URI', function()
        local decoded = assert(
            uri.decode('terminalia://terminal/contexts/context/host/Host/context:host/terminal/terminal:1/terminal:1')
        )

        assert.are.equal('terminal:1', decoded.terminal_id)
        assert.are.equal('terminal:1', decoded.name)
        assert.are.equal('context:host', decoded.context_id)
    end)

    it('reads old marker-based metadata', function()
        local decoded = assert(
            uri.decode(
                'terminalia://history/contexts/context/host/Host/context:host/'
                    .. 'context/devcontainer/app/context:1/meta/config_path/%2Ftmp%2Fconfig.json/terminal/terminal:1/build'
            )
        )

        assert.are.equal('history', decoded.kind)
        assert.are.equal('build', decoded.name)
        assert.are.equal('/tmp/config.json', decoded.context_stack[2].metadata.config_path)
    end)

    it('reads unmarked legacy context stacks and schemes', function()
        local decoded =
            assert(uri.decode('terminal-manager://terminal/contexts/host/Host/context:host/terminal/terminal:1/build'))

        assert.are.equal('terminal:1', decoded.terminal_id)
        assert.are.equal('build', decoded.name)
        assert.are.same({ 'context:host' }, decoded.context_stack_ids)
    end)
end)

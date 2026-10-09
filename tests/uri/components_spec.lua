local components = require('terminalia.uri.components')

describe('terminalia.uri.components', function()
    it('escapes delimiters, whitespace, and control bytes', function()
        local value = 'name /?&=;:#%@\001'
        local encoded = components.encode(value)

        assert.are.equal('name%20%2F%3F%26%3D%3B%3A%23%25%40%01', encoded)
        assert.are.equal(value, components.decode(encoded))
    end)

    it('distinguishes prefixed ids from literal ids', function()
        local examples = { 'terminal:1', 'terminal:build', '1', 'build', 'terminal:', 'terminal:build:1' }
        local encoded = {}

        for _, id in ipairs(examples) do
            local value = components.encode_id(id, 'terminal:')
            assert.is_nil(encoded[value])
            encoded[value] = true
            assert.are.equal(id, components.decode_id(value, 'terminal:'))
        end

        assert.are.equal('1', components.encode_id('terminal:1', 'terminal:'))
        assert.are.equal('@1', components.encode_id('1', 'terminal:'))
    end)

    it('rejects incomplete or non-hexadecimal escapes', function()
        for _, value in ipairs({ '%', '%1', '%zz', 'ok%20bad%' }) do
            assert.is_false(components.valid_encoding(value))
        end

        assert.is_true(components.valid_encoding('ok%20%25%3A'))
    end)
end)

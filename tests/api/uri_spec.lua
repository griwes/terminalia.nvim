local plugin = require('terminalia')

describe('terminalia.api URI migration', function()
    local state_file
    local history_dir
    local buffers
    local original_bufnr

    before_each(function()
        state_file = vim.fn.tempname()
        history_dir = vim.fn.tempname()
        buffers = {}
        original_bufnr = vim.api.nvim_get_current_buf()
        plugin.setup({
            state_file = state_file,
            history_dir = history_dir,
            persist_terminals = false,
            persist_history = true,
            notify_on_exit = false,
            enable_editor_shell_integration = false,
            enable_parent_nvim_redirect = false,
        })
        plugin.api.clear()
    end)

    after_each(function()
        plugin.api.clear()

        if vim.api.nvim_buf_is_valid(original_bufnr) then
            vim.api.nvim_set_current_buf(original_bufnr)
        end

        for _, bufnr in ipairs(buffers) do
            if vim.api.nvim_buf_is_valid(bufnr) then
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        end

        vim.fn.delete(state_file)
        vim.fn.delete(state_file .. '.d', 'rf')
        vim.fn.delete(history_dir, 'rf')
    end)

    local function legacy_buffer(kind, id)
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(
            bufnr,
            'terminalia://' .. kind .. '/contexts/context/host/Host/context:host/terminal/' .. id .. '/' .. id
        )
        buffers[#buffers + 1] = bufnr
        return bufnr
    end

    it('adopts a legacy terminal in place with its compact name', function()
        local terminal = plugin.api.create({ id = 'terminal:7' })
        local bufnr = legacy_buffer('terminal', terminal.id)
        local adopted = plugin.api.adopt_uri_buffer(bufnr)

        assert.are.equal(terminal.id, adopted.id)
        assert.are.equal(bufnr, adopted.bufnr)
        assert.are.equal('terminalia://7', vim.api.nvim_buf_get_name(bufnr))
        assert.are.equal(original_bufnr, vim.api.nvim_get_current_buf())
    end)

    it('adopts legacy history in place with its compact name and contents', function()
        local terminal = plugin.api.create({ id = 'terminal:8' })
        local history = require('terminalia.history')
        history.append_chunks(terminal.id, { 'saved output', '' })
        history.flush(terminal.id)
        local bufnr = legacy_buffer('history', terminal.id)

        assert.are.equal(bufnr, plugin.api.adopt_uri_buffer(bufnr))
        assert.are.equal('terminalia://8/history', vim.api.nvim_buf_get_name(bufnr))
        assert.are.same({ 'saved output' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
        assert.are.equal('nofile', vim.bo[bufnr].buftype)
    end)

    it('reuses an existing canonical history view when adopting a legacy alias', function()
        local terminal = plugin.api.create({ id = 'terminal:9' })
        plugin.api.open_history(terminal.id)
        local canonical = vim.api.nvim_get_current_buf()
        buffers[#buffers + 1] = canonical
        local alias = legacy_buffer('history', terminal.id)

        assert.are.equal(canonical, plugin.api.adopt_uri_buffer(alias))
        assert.are.equal(canonical, vim.api.nvim_get_current_buf())
        assert.are.equal('terminalia://9/history', vim.api.nvim_buf_get_name(canonical))
        assert.is_false(vim.api.nvim_buf_is_valid(alias))
    end)
end)

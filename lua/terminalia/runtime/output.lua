local M = {}
local cwd_fallback_prefix = '__TERMINALIA_CWD__='

---@param state table
---@param deps table
---@return table
function M.new(state, deps)
    local helper = {}

    ---@param chunk string
    ---@return boolean
    local function is_cwd_fallback_chunk(chunk)
        return type(chunk) == 'string' and vim.startswith(chunk, cwd_fallback_prefix)
    end

    ---@param id string
    ---@param data? string[]
    function helper.append_output(id, data)
        if data == nil or #data == 0 then
            return
        end

        local tail = state.pending_output[id] or ''
        local pieces = {}

        for index, chunk in ipairs(data) do
            local value = chunk

            if index == 1 then
                value = tail .. value
            end

            if is_cwd_fallback_chunk(value) then
                value = ''
            end

            if index == #data then
                state.pending_output[id] = value
            else
                if value ~= '' then
                    table.insert(pieces, value)
                end
            end
        end

        if #pieces == 0 then
            return
        end

        local text = table.concat(pieces, '\n') .. '\n'
        state.captured_output[id] = (state.captured_output[id] or '') .. text
    end

    ---@param id string
    ---@return terminalia.TerminalRecord?
    function helper.current_terminal(id)
        return deps.registry.get(id) or state.exited_disposables[id]
    end

    ---@param id string
    ---@param opts? { bufnr?: integer, event?: string }
    function helper.finalize_disposable(id, opts)
        if state.pending_disposable_cleanup[id] ~= true then
            return false
        end

        local terminal = state.exited_disposables[id]
        local bufnr = terminal and terminal.bufnr or state.disposable_bufnrs[id]
        local target_bufnr = opts and opts.bufnr or nil

        if target_bufnr ~= nil and bufnr ~= nil and target_bufnr ~= bufnr then
            return false
        end

        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            local wins = deps.visible_windows_for_buffer(bufnr)
            if #wins > 0 then
                return false
            end

            if opts and opts.event == 'WinClosed' then
                vim.schedule(function()
                    helper.finalize_disposable(id, { bufnr = bufnr })
                end)
                return false
            end

            if opts and opts.event == 'BufWipeout' then
                vim.schedule(function()
                    helper.finalize_disposable(id, { bufnr = bufnr })
                end)
                return false
            end

            if opts and opts.event == 'BufHidden' then
                local post_hide_wins = deps.visible_windows_for_buffer(bufnr)
                if #post_hide_wins > 0 then
                    vim.schedule(function()
                        helper.finalize_disposable(id, { bufnr = bufnr })
                    end)
                    return false
                end
            end

            if bufnr == vim.api.nvim_get_current_buf() then
                vim.cmd('enew')
            end

            for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
                if vim.api.nvim_win_is_valid(winid) then
                    pcall(vim.api.nvim_win_set_buf, winid, vim.api.nvim_create_buf(false, true))
                end
            end

            state.pending_disposable_cleanup[id] = 'finalizing'
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            if vim.api.nvim_buf_is_valid(bufnr) then
                state.pending_disposable_cleanup[id] = true
                return false
            end
        end

        state.pending_disposable_cleanup[id] = nil
        state.exited_disposables[id] = nil
        state.disposable_bufnrs[id] = nil
        deps.history.clear(id)
        helper.clear_output(id)
        return true
    end

    ---@param bufnr integer
    function helper.detach_buffer_from_windows(bufnr)
        if bufnr == vim.api.nvim_get_current_buf() then
            vim.cmd('enew')
        end

        for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
            if vim.api.nvim_win_is_valid(winid) then
                pcall(vim.api.nvim_win_set_buf, winid, vim.api.nvim_create_buf(false, true))
            end
        end
    end

    ---@param id string
    ---@return string, boolean
    function helper.output(id)
        local has_output = state.captured_output[id] ~= nil or state.pending_output[id] ~= nil
        local output = (state.captured_output[id] or '') .. (state.pending_output[id] or '')

        return output, has_output
    end

    ---@param id string
    ---@return terminalia.TerminalRecord?
    function helper.exited_terminal(id)
        return helper.current_terminal(id)
    end

    ---@param id string
    function helper.forget_exited_terminal(id)
        state.pending_disposable_cleanup[id] = nil
        state.exited_disposables[id] = nil
        state.disposable_bufnrs[id] = nil
    end

    ---@param id string
    ---@return terminalia.TerminalRecord?
    function helper.release_exited_terminal(id)
        local released = helper.current_terminal(id)

        if released == nil then
            return nil
        end

        if not helper.finalize_disposable(id) then
            local bufnr = released.bufnr or state.disposable_bufnrs[id]

            if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
                helper.detach_buffer_from_windows(bufnr)
                pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            end

            state.pending_disposable_cleanup[id] = nil
            state.exited_disposables[id] = nil
            state.disposable_bufnrs[id] = nil
            deps.history.clear(id)
            helper.clear_output(id)
        end

        return released
    end

    ---@param id string
    function helper.clear_output(id)
        state.captured_output[id] = nil
        state.pending_output[id] = nil
    end

    return helper
end

return M

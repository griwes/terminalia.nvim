local M = {}

---@param state table
---@param deps table
---@return table
function M.new(state, deps)
    local helper = {}

    ---@param terminal terminalia.TerminalRecord
    ---@return string
    local function terminal_buffer_name(terminal)
        return deps.uri.encode_terminal_uri(terminal)
    end

    ---@param terminal terminalia.TerminalRecord
    ---@param bufnr integer
    ---@return string
    local function displaced_terminal_buffer_name(terminal, bufnr)
        return string.format('terminalia-displaced://%s/%d', terminal.id, bufnr)
    end

    ---@param target_name string
    ---@param owner_bufnr integer
    ---@param terminal terminalia.TerminalRecord
    local function displace_conflicting_buffer(target_name, owner_bufnr, terminal)
        local existing = vim.fn.bufnr(target_name)

        if existing <= 0 or existing == owner_bufnr or not vim.api.nvim_buf_is_valid(existing) then
            return
        end

        pcall(vim.api.nvim_buf_set_name, existing, displaced_terminal_buffer_name(terminal, existing))
    end

    ---@param bufnr integer
    ---@param terminal terminalia.TerminalRecord
    function helper.set_terminal_buffer_name(bufnr, terminal)
        local target_name = terminal_buffer_name(terminal)
        displace_conflicting_buffer(target_name, bufnr, terminal)
        vim.api.nvim_buf_set_name(bufnr, target_name)
    end

    ---@param listed boolean
    ---@return integer
    local function create_runtime_buffer(listed)
        local bufnr = vim.api.nvim_create_buf(listed, false)

        if vim.bo[bufnr].buftype == 'nofile' then
            vim.bo[bufnr].buftype = ''
        end

        return bufnr
    end

    ---@param terminal terminalia.TerminalRecord
    ---@return integer
    function helper.ensure_buffer(terminal)
        if terminal.bufnr and vim.api.nvim_buf_is_valid(terminal.bufnr) then
            return terminal.bufnr
        end

        local bufnr = create_runtime_buffer(false)

        vim.bo[bufnr].bufhidden = 'hide'
        vim.bo[bufnr].swapfile = false
        helper.set_terminal_buffer_name(bufnr, terminal)
        vim.b[bufnr].terminalia_id = terminal.id

        deps.registry.update(terminal.id, {
            bufnr = bufnr,
        })

        return bufnr
    end

    ---@param bufnr integer
    ---@return table<string, integer[]>
    local function capture_named_marks(bufnr)
        local marks = {}

        for code = string.byte('a'), string.byte('z') do
            local name = string.char(code)
            local mark = vim.api.nvim_buf_get_mark(bufnr, name)

            if mark[1] > 0 then
                marks[name] = mark
            end
        end

        return marks
    end

    ---@param terminal terminalia.TerminalRecord
    function helper.capture_buffer_state(terminal)
        local bufnr = terminal.bufnr

        if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
            state.buffer_state[terminal.id] = nil
            return
        end

        state.buffer_state[terminal.id] = {
            marks = capture_named_marks(bufnr),
        }
    end

    ---@param terminal terminalia.TerminalRecord
    ---@return integer, fun(): integer
    function helper.prepare_restarted_terminal_buffer(terminal)
        helper.capture_buffer_state(terminal)

        local original_bufnr = terminal.bufnr
        local replacement_bufnr = create_runtime_buffer(false)

        if replacement_bufnr == 0 then
            error(string.format('Failed to create buffer for terminal %s', terminal.id))
        end

        vim.bo[replacement_bufnr].bufhidden = 'hide'
        vim.bo[replacement_bufnr].swapfile = false
        helper.set_terminal_buffer_name(replacement_bufnr, terminal)
        vim.b[replacement_bufnr].terminalia_id = terminal.id

        local function commit()
            local updated = deps.registry.update(terminal.id, {
                bufnr = replacement_bufnr,
            })

            if original_bufnr and vim.api.nvim_buf_is_valid(original_bufnr) then
                vim.schedule(function()
                    if vim.api.nvim_buf_is_valid(original_bufnr) then
                        pcall(vim.api.nvim_buf_delete, original_bufnr, { force = true })
                    end
                end)
            end

            return updated.bufnr or replacement_bufnr
        end

        return replacement_bufnr, commit
    end

    ---@param terminal terminalia.TerminalRecord
    ---@param bufnr integer
    function helper.restore_buffer_state(terminal, bufnr)
        local captured = state.buffer_state[terminal.id]

        if captured == nil then
            return
        end

        for mark, position in pairs(captured.marks or {}) do
            pcall(vim.api.nvim_buf_set_mark, bufnr, mark, position[1], position[2], {})
        end

        state.buffer_state[terminal.id] = nil
    end

    local hidden_terminal_events = { 'BufEnter', 'BufLeave' }

    ---@param eventignore string
    ---@return string
    local function add_hidden_terminal_events(eventignore)
        local seen = {}
        local events = {}

        for event in string.gmatch(eventignore, '[^,]+') do
            if not seen[event] then
                seen[event] = true
                events[#events + 1] = event
            end
        end

        for _, event in ipairs(hidden_terminal_events) do
            if not seen[event] then
                events[#events + 1] = event
            end
        end

        return table.concat(events, ',')
    end

    ---@return integer
    local function ensure_hidden_startup_window()
        if state.hidden_startup_window ~= nil and vim.api.nvim_win_is_valid(state.hidden_startup_window) then
            return state.hidden_startup_window
        end

        local previous_tabpage = vim.api.nvim_get_current_tabpage()
        local previous_winid = vim.api.nvim_get_current_win()
        local previous_ei = vim.o.eventignore

        vim.o.eventignore = add_hidden_terminal_events(previous_ei)
        vim.cmd('silent keepalt noautocmd tabnew')

        state.hidden_startup_tabpage = vim.api.nvim_get_current_tabpage()
        state.hidden_startup_window = vim.api.nvim_get_current_win()

        pcall(vim.api.nvim_set_current_tabpage, previous_tabpage)
        pcall(vim.api.nvim_set_current_win, previous_winid)
        vim.o.eventignore = previous_ei

        return state.hidden_startup_window
    end

    ---@return integer
    local function ensure_hidden_startup_scratch_buffer()
        if
            state.hidden_startup_scratch_bufnr ~= nil
            and vim.api.nvim_buf_is_valid(state.hidden_startup_scratch_bufnr)
        then
            return state.hidden_startup_scratch_bufnr
        end

        state.hidden_startup_scratch_bufnr = vim.api.nvim_create_buf(false, true)

        return state.hidden_startup_scratch_bufnr
    end

    function helper.cleanup_hidden_startup_window()
        if state.hidden_startup_window ~= nil and vim.api.nvim_win_is_valid(state.hidden_startup_window) then
            pcall(vim.api.nvim_win_set_buf, state.hidden_startup_window, ensure_hidden_startup_scratch_buffer())
        end

        if state.hidden_startup_tabpage ~= nil and vim.api.nvim_tabpage_is_valid(state.hidden_startup_tabpage) then
            pcall(vim.api.nvim_tabpage_close, state.hidden_startup_tabpage, true)
        end

        state.hidden_startup_tabpage = nil
        state.hidden_startup_window = nil
    end

    ---@param bufnr integer
    ---@return integer[]
    function helper.visible_windows_for_buffer(bufnr)
        local wins = vim.fn.win_findbuf(bufnr)

        if wins == nil or #wins == 0 then
            return {}
        end

        return vim.tbl_filter(function(winid)
            return state.hidden_startup_window == nil or winid ~= state.hidden_startup_window
        end, wins)
    end

    ---@param bufnr integer
    ---@param callback fun(): integer
    ---@return integer
    function helper.with_hidden_terminal_window(bufnr, callback)
        local previous_ei = vim.o.eventignore
        local previous_tabpage = vim.api.nvim_get_current_tabpage()
        local previous_winid = vim.api.nvim_get_current_win()
        local hidden_winid = ensure_hidden_startup_window()

        local ok, result = xpcall(function()
            vim.o.eventignore = add_hidden_terminal_events(previous_ei)
            vim.api.nvim_set_current_win(hidden_winid)
            vim.api.nvim_win_set_buf(hidden_winid, bufnr)
            return callback()
        end, debug.traceback)

        pcall(vim.api.nvim_set_current_tabpage, previous_tabpage)
        pcall(vim.api.nvim_set_current_win, previous_winid)
        helper.cleanup_hidden_startup_window()
        vim.o.eventignore = previous_ei

        if not ok then
            error(result)
        end

        return result
    end

    return helper
end

return M

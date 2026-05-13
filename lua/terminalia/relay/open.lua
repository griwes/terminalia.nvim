local config = require('terminalia.config')

local M = {}

---@param target terminalia.ExternalOpenTarget
local function apply_position(target)
    if target.line == nil then
        return
    end

    local line_count = vim.api.nvim_buf_line_count(0)
    local line = math.min(math.max(target.line, 1), math.max(line_count, 1))
    local col = math.max((target.col or 1) - 1, 0)

    vim.api.nvim_win_set_cursor(0, { line, col })
end

---@param command string
---@param path string
local function edit_with(command, path)
    vim.cmd(string.format('%s %s', command, vim.fn.fnameescape(path)))
end

---@return table?
local function active_tabulature()
    if package.loaded['tabulature'] == nil and package.loaded['tabulature.state'] == nil then
        return nil
    end

    local ok, tabulature = pcall(require, 'tabulature')
    if not ok or type(tabulature) ~= 'table' then
        return nil
    end

    return tabulature
end

---@return any?
local function current_tabulature_tab_id()
    local tabulature = active_tabulature()
    if tabulature == nil or type(tabulature.current_tab_id) ~= 'function' then
        return nil
    end

    local ok, tab_id = pcall(tabulature.current_tab_id)
    if not ok then
        return nil
    end

    return tab_id
end

---@param parent_id any?
local function adopt_tabulature_child(parent_id)
    if parent_id == nil then
        return
    end

    local tabulature = active_tabulature()
    if tabulature == nil or type(tabulature.adopt_current_tabpage) ~= 'function' then
        return
    end

    pcall(tabulature.adopt_current_tabpage, { parent_id = parent_id })
end

---@param path string
---@return boolean
local function focus_existing_window(path)
    for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
        for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
            local bufnr = vim.api.nvim_win_get_buf(winid)

            if vim.api.nvim_buf_get_name(bufnr) == path then
                vim.api.nvim_set_current_tabpage(tabpage)
                vim.api.nvim_set_current_win(winid)
                return true
            end
        end
    end

    return false
end

local function name_stdin_buffer()
    local base_name = 'terminalia://external/stdin'

    if pcall(vim.api.nvim_buf_set_name, 0, base_name) then
        return
    end

    for index = 2, 1024 do
        if pcall(vim.api.nvim_buf_set_name, 0, string.format('%s/%d', base_name, index)) then
            return
        end
    end

    error('Terminalia could not assign a unique stdin scratch buffer name')
end

---@param target terminalia.ExternalOpenTarget
---@param stdin_data? string|string[]
local function open_stdin(target, stdin_data)
    vim.cmd('enew')
    vim.bo.buftype = 'nofile'
    vim.bo.bufhidden = 'wipe'
    vim.bo.swapfile = false
    name_stdin_buffer()

    if type(stdin_data) == 'string' then
        vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(stdin_data, '\n', { plain = true }))
    elseif type(stdin_data) == 'table' then
        vim.api.nvim_buf_set_lines(0, 0, -1, false, stdin_data)
    end

    apply_position(target)
end

---@param target terminalia.ExternalOpenTarget
---@param policy terminalia.ExternalOpenPolicy
local function open_file(target, policy)
    local path = assert(target.path, 'external open target missing path')

    if policy == 'tab' then
        local tabulature_parent = current_tabulature_tab_id()
        edit_with('tabedit', path)
        adopt_tabulature_child(tabulature_parent)
    elseif policy == 'split' then
        edit_with('split', path)
    elseif policy == 'vsplit' then
        edit_with('vsplit', path)
    elseif policy == 'float' then
        local bufnr = vim.fn.bufadd(path)
        vim.fn.bufload(bufnr)

        local float_cfg = config.get().float
        local width = math.max(10, math.floor(vim.o.columns * float_cfg.width))
        local height = math.max(10, math.floor((vim.o.lines - vim.o.cmdheight) * float_cfg.height))
        local row = math.floor((vim.o.lines - height) / 2)
        local col = math.floor((vim.o.columns - width) / 2)

        vim.api.nvim_open_win(bufnr, true, {
            relative = 'editor',
            row = row,
            col = col,
            width = width,
            height = height,
            style = 'minimal',
            border = float_cfg.border,
        })
    elseif policy == 'reuse' and focus_existing_window(path) then
        -- Existing window is now current.
    else
        edit_with('edit', path)
    end

    apply_position(target)
end

---@param command string
---@param target terminalia.ExternalOpenTarget
local function open_diff_file(command, target)
    edit_with(command, assert(target.path, 'external diff target missing path'))
    apply_position(target)
    vim.cmd('diffthis')
end

---@param targets terminalia.ExternalOpenTarget[]
---@param stdin_data? string|string[]
local function open_diff_targets(targets, stdin_data)
    if #targets == 0 then
        return
    end

    local first = targets[1]

    if first.stdin then
        open_stdin(first, stdin_data)
        vim.cmd('diffthis')
    else
        open_diff_file('edit', first)
    end

    for index = 2, #targets do
        local target = targets[index]

        if target.stdin then
            open_stdin(target, stdin_data)
            vim.cmd('diffthis')
        else
            open_diff_file('vertical diffsplit', target)
        end
    end
end

---@param commands string[]
local function run_commands(commands)
    for _, command in ipairs(commands) do
        vim.cmd(command)
    end
end

---@param plan terminalia.ExternalOpenPlan
---@param opts? { stdin_data?: string|string[] }
---@return terminalia.ExternalOpenTarget[]
function M.open_plan(plan, opts)
    opts = opts or {}

    run_commands(plan.pre_commands or {})

    local commands = plan.commands or {}
    local commands_applied = false

    local function apply_commands()
        if commands_applied then
            return
        end

        commands_applied = true

        run_commands(commands)
    end

    local targets = plan.targets or {}

    if plan.diff then
        open_diff_targets(targets, opts.stdin_data)
        apply_commands()
        return targets
    end

    for _, target in ipairs(targets) do
        if target.stdin then
            open_stdin(target, opts.stdin_data)
        else
            open_file(target, plan.open_policy)
        end

        apply_commands()
    end

    apply_commands()

    return plan.targets
end

return M

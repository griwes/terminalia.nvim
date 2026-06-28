local config = require('terminalia.config')
local api = require('terminalia.api')
local commands = require('terminalia.commands')
local contexts = require('terminalia.context.state')
local persistence = require('terminalia.persistence')
local parent_redirect = require('terminalia.relay.parent')
local runtime = require('terminalia.runtime.native')

---@class terminalia.RootModule
---@field config terminalia.Config
---@field api table

local M = {}
local last_persistence_config
local uri_autocmds_registered = false
local adopting_uri_buffer = false

---@package
function M._reset_setup_state()
    last_persistence_config = nil
    uri_autocmds_registered = false
    adopting_uri_buffer = false
end

---@param cfg terminalia.Config
---@return table
local function persistence_config_snapshot(cfg)
    return {
        persist_terminals = cfg.persist_terminals,
        state_file = cfg.state_file,
    }
end

---@param left? table
---@param right table
---@return boolean
local function persistence_config_changed(left, right)
    return left == nil or left.persist_terminals ~= right.persist_terminals or left.state_file ~= right.state_file
end

---@param left? table
---@param right table
---@return boolean
local function persistence_enabled_transitioned(left, right)
    return left ~= nil and left.persist_terminals ~= true and right.persist_terminals == true
end

---@param left? table
---@param right table
---@return boolean
local function persistence_state_file_changed(left, right)
    return left ~= nil and left.state_file ~= right.state_file
end

---@param left? table
---@param right table
---@return boolean
local function persistence_disabled(left, right)
    return left ~= nil and left.persist_terminals == true and right.persist_terminals ~= true
end

local function clear_persistence_file(path)
    persistence.clear_path(path)
end

local function ensure_uri_autocmds()
    if uri_autocmds_registered then
        return
    end

    local group = vim.api.nvim_create_augroup('terminalia-uri-adoption', {
        clear = true,
    })

    local function adopt_terminalia_uri_buffer(args)
        if adopting_uri_buffer then
            return
        end

        local bufnr = args.buf or vim.api.nvim_get_current_buf()

        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end

        local name = vim.api.nvim_buf_get_name(bufnr)
        if not vim.startswith(name, 'terminalia://') and not vim.startswith(name, 'terminal-manager://') then
            return
        end

        if vim.b[bufnr].terminalia_history_view == true then
            return
        end

        if vim.bo[bufnr].buftype == 'terminal' then
            return
        end

        adopting_uri_buffer = true
        local ok, err = pcall(api.adopt_uri_buffer, bufnr)
        adopting_uri_buffer = false

        if not ok then
            vim.schedule(function()
                vim.notify(string.format('Failed to adopt Terminalia buffer: %s', err), vim.log.levels.ERROR)
            end)
        end
    end

    vim.api.nvim_create_autocmd({ 'BufReadCmd', 'BufNewFile' }, {
        group = group,
        pattern = { 'terminalia://*', 'terminal-manager://*' },
        callback = adopt_terminalia_uri_buffer,
    })

    vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
        group = group,
        callback = adopt_terminalia_uri_buffer,
    })

    uri_autocmds_registered = true
end

M.config = config.get()
M.api = api
contexts.clear()
commands.ensure(M)

---Configure Terminalia.
---@param opts? Partial<terminalia.Config>
---@return terminalia.Config
function M.setup(opts)
    local active_config = config.get()
    local next_config = config.preview(opts, active_config)

    if parent_redirect.try_child_redirect({
        enabled = next_config.enable_parent_nvim_redirect,
    }) then
        return M.config
    end

    local current_persistence_config = persistence_config_snapshot(next_config)
    local state_file_changed = persistence_state_file_changed(last_persistence_config, current_persistence_config)
    local disabling_persistence = persistence_disabled(last_persistence_config, current_persistence_config)
    local force_restore = persistence_config_changed(last_persistence_config, current_persistence_config)
        and not (disabling_persistence and not state_file_changed)
    local merge_restore = persistence_enabled_transitioned(last_persistence_config, current_persistence_config)

    if disabling_persistence then
        clear_persistence_file(last_persistence_config.state_file)

        if current_persistence_config.state_file ~= last_persistence_config.state_file then
            clear_persistence_file(current_persistence_config.state_file)
        end
    end

    M.config = config.set(next_config)

    if last_persistence_config ~= nil and state_file_changed and force_restore and not merge_restore then
        api.clear({
            wipe_storage = false,
            reset_setup_state = false,
        })
    end

    if last_persistence_config ~= nil and disabling_persistence and state_file_changed then
        api.clear({
            wipe_storage = false,
            reset_setup_state = false,
        })
    end

    runtime.ensure_autocmds()
    ensure_uri_autocmds()
    current_persistence_config = persistence_config_snapshot(M.config)

    api.restore({
        force = last_persistence_config ~= nil and force_restore,
        merge = merge_restore,
    })

    pcall(api.setup_ministry_integration)

    local ok, session_plugin = pcall(require, 'continuity')

    if ok and type(session_plugin) == 'table' and type(session_plugin.api) == 'table' then
        if type(session_plugin.api.register_contributor) == 'function' then
            local registered, err = pcall(session_plugin.api.register_contributor, 'terminalia', {
                capture = api.session_capture,
                plan_restore = api.session_plan_restore,
                restore = api.session_restore,
                restore_phase = 'after_layout',
                restore_after = { 'arboretum', 'consulate', 'laboratory' },
            })

            if not registered then
                vim.notify(
                    string.format('Failed to register Terminalia session contributor: %s', err),
                    vim.log.levels.WARN
                )
            end

            local legacy_registered, legacy_err = pcall(session_plugin.api.register_contributor, 'terminal_manager', {
                plan_restore = api.session_plan_restore,
                restore = api.session_restore,
                restore_phase = 'after_layout',
                restore_after = { 'arboretum', 'consulate', 'laboratory' },
            })

            if not legacy_registered then
                vim.notify(
                    string.format('Failed to register legacy Terminalia session contributor: %s', legacy_err),
                    vim.log.levels.WARN
                )
            end
        end
    end

    last_persistence_config = current_persistence_config
    return M.config
end

return M

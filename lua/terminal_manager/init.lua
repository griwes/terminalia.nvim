local config = require('terminal_manager.config')
local api = require('terminal_manager.api')
local commands = require('terminal_manager.commands')
local persistence = require('terminal_manager.persistence')
local runtime = require('terminal_manager.runtime.native')

---@class terminal_manager.RootModule
---@field config terminal_manager.Config
---@field api table

local M = {}
local last_persistence_config

---@package
function M._reset_setup_state()
    last_persistence_config = nil
end

---@param cfg terminal_manager.Config
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
    if vim.fn.filereadable(path) == 1 then
        vim.fn.delete(path)
    end
end

M.config = config.get()
M.api = api
commands.ensure(M)

---Configure terminal-manager.
---@param opts? Partial<terminal_manager.Config>
---@return terminal_manager.Config
function M.setup(opts)
    local active_config = config.get()
    local next_config = config.preview(opts, active_config)
    local current_persistence_config = persistence_config_snapshot(next_config)
    local state_file_changed = persistence_state_file_changed(last_persistence_config, current_persistence_config)
    local disabling_persistence = persistence_disabled(last_persistence_config, current_persistence_config)
    local force_restore = persistence_config_changed(last_persistence_config, current_persistence_config)
    local merge_restore = persistence_enabled_transitioned(last_persistence_config, current_persistence_config)

    if disabling_persistence then
        clear_persistence_file(last_persistence_config.state_file)

        if current_persistence_config.state_file ~= last_persistence_config.state_file then
            clear_persistence_file(current_persistence_config.state_file)
        end
    end

    M.config = config.set(next_config, active_config)

    if last_persistence_config ~= nil and state_file_changed and force_restore and not merge_restore then
        api.clear({
            wipe_storage = false,
        })
    end

    runtime.ensure_autocmds()
    current_persistence_config = persistence_config_snapshot(M.config)

    api.restore({
        force = force_restore,
        merge = merge_restore,
    })

    last_persistence_config = current_persistence_config
    return M.config
end

return M

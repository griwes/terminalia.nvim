local model = require('terminal_manager.model')

local M = {}

---@class terminal_manager.PersistencePayload
---@field next_id integer
---@field terminals terminal_manager.TerminalRecord[]

---@return string
local function state_file()
    return require('terminal_manager.config').get().state_file
end

---@return terminal_manager.PersistencePayload
local function empty_payload()
    return {
        next_id = 1,
        terminals = {},
    }
end

---@return string
local function state_dir()
    return vim.fn.fnamemodify(state_file(), ':h')
end

---Load persisted terminal metadata from disk.
---@return terminal_manager.PersistencePayload
function M.load()
    local path = state_file()

    if vim.fn.filereadable(path) == 0 then
        return empty_payload()
    end

    local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))

    if not ok or type(decoded) ~= 'table' then
        return empty_payload()
    end

    local next_id = tonumber(decoded.next_id) or 1
    local terminals = {}

    for _, item in ipairs(decoded.terminals or {}) do
        if type(item) == 'table' and model.is_string_id(item.id) then
            table.insert(terminals, model.restore_terminal(item))
        end
    end

    return {
        next_id = next_id,
        terminals = terminals,
    }
end

---Persist terminal metadata to disk.
---@param payload terminal_manager.PersistencePayload
function M.save(payload)
    local path = state_file()

    vim.fn.mkdir(state_dir(), 'p')
    vim.fn.writefile({
        vim.json.encode({
            next_id = payload.next_id,
            terminals = vim.tbl_map(model.to_persisted_record, payload.terminals),
        }),
    }, path)
end

---Delete the persisted state file if it exists.
function M.clear()
    local path = state_file()

    if vim.fn.filereadable(path) == 1 then
        vim.fn.delete(path)
    end
end

return M

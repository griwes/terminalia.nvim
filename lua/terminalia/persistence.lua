local model = require('terminalia.terminal.model')

local M = {}

---@class terminalia.PersistencePayload
---@field next_id integer
---@field terminals terminalia.TerminalRecord[]
---@field next_context_id integer
---@field current_context_id string
---@field contexts terminalia.PersistedContext[]

---@return string
local function state_file()
    return require('terminalia.config').get().state_file
end

---@return terminalia.PersistencePayload
local function empty_payload()
    return {
        next_id = 1,
        terminals = {},
        next_context_id = 1,
        current_context_id = 'context:host',
        contexts = {},
    }
end

---@return string
local function state_dir()
    return vim.fn.fnamemodify(state_file(), ':h')
end

---Load persisted terminal metadata from disk.
---@return terminalia.PersistencePayload
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

    for index, item in ipairs(decoded.terminals or {}) do
        if type(item) == 'table' and model.is_string_id(item.id) then
            local restored_item = vim.deepcopy(item)
            restored_item.restored_index = index
            table.insert(terminals, model.restore_terminal(restored_item))
        end
    end

    return {
        next_id = next_id,
        terminals = terminals,
        next_context_id = tonumber(decoded.next_context_id) or 1,
        current_context_id = type(decoded.current_context_id) == 'string' and decoded.current_context_id
            or 'context:host',
        contexts = type(decoded.contexts) == 'table' and vim.deepcopy(decoded.contexts) or {},
    }
end

---Persist terminal metadata to disk.
---@param payload terminalia.PersistencePayload
function M.save(payload)
    local path = state_file()

    vim.fn.mkdir(state_dir(), 'p')
    vim.fn.writefile({
        vim.json.encode({
            next_id = payload.next_id,
            next_context_id = payload.next_context_id,
            current_context_id = payload.current_context_id,
            terminals = vim.tbl_map(model.to_persisted_record, payload.terminals),
            contexts = payload.contexts,
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

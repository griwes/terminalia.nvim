local model = require('terminalia.terminal.model')

local M = {}
local CURRENT_VERSION = 1

---@class terminalia.PersistencePayload
---@field next_id integer
---@field terminals terminalia.TerminalRecord[]
---@field next_context_id integer
---@field current_context_id string
---@field contexts terminalia.PersistedContext[]

---@param path? string
---@return string
local function state_file(path)
    return path or require('terminalia.config').get().state_file
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

---@param path? string
---@return string
local function state_dir(path)
    return string.format('%s.d', state_file(path))
end

---@param value string
---@return string
local function encode_path_component(value)
    return value:gsub('[^%w._-]', function(char)
        return string.format('%%%02X', char:byte())
    end)
end

---@param id string
---@return string
local function record_filename(id)
    return string.format('%s.json', encode_path_component(id))
end

---@param path string
---@param payload table
local function write_json(path, payload)
    local parent = vim.fn.fnamemodify(path, ':h')
    vim.fn.mkdir(parent, 'p')

    local encoded_ok, encoded = pcall(vim.json.encode, payload)
    if not encoded_ok then
        error(string.format('Failed to encode Terminalia persistence record %s: %s', path, encoded))
    end

    local temporary = string.format('%s.tmp.%d.%d', path, vim.fn.getpid(), vim.uv.hrtime())
    local write_ok, write_result = pcall(vim.fn.writefile, { encoded }, temporary)
    if not write_ok or write_result ~= 0 then
        vim.uv.fs_unlink(temporary)
        error(string.format('Failed to write Terminalia persistence temporary %s: %s', temporary, write_result))
    end

    local renamed, rename_err = vim.uv.fs_rename(temporary, path)
    if not renamed then
        vim.uv.fs_unlink(temporary)
        error(string.format('Failed to replace Terminalia persistence record %s: %s', path, rename_err))
    end
end

---@param path string
---@return table?
local function read_json(path)
    if vim.fn.filereadable(path) == 0 then
        return nil
    end

    local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))
    if not ok or type(decoded) ~= 'table' then
        return nil
    end

    return decoded
end

---@param root string
---@param kind '"terminals"'|'"contexts"'
---@param id string
---@return string
local function record_path(root, kind, id)
    return vim.fs.joinpath(root, kind, record_filename(id))
end

---@param terminal terminalia.TerminalRecord
---@return table
local function terminal_index_entry(terminal)
    return {
        id = terminal.id,
        name = terminal.name,
        namespace = terminal.namespace,
        cwd = terminal.cwd,
        context_id = terminal.context_id,
        status = terminal.status,
        file = record_filename(terminal.id),
    }
end

---@param context terminalia.PersistedContext
---@return table
local function context_index_entry(context)
    return {
        id = context.id,
        kind = context.kind,
        label = context.label,
        parent_id = context.parent_id,
        file = record_filename(context.id),
    }
end

---@param root string
---@param entry table
---@param index integer
---@return terminalia.TerminalRecord?
local function load_terminal_record(root, entry, index)
    if type(entry) ~= 'table' or not model.is_valid_id(entry.id) then
        return nil
    end

    local filename = type(entry.file) == 'string' and entry.file or record_filename(entry.id)
    local decoded = read_json(vim.fs.joinpath(root, 'terminals', filename))

    if decoded == nil then
        return nil
    end

    decoded.restored_index = index
    return model.restore_terminal(decoded)
end

---@param root string
---@param entry table
---@return terminalia.PersistedContext?
local function load_context_record(root, entry)
    if type(entry) ~= 'table' or type(entry.id) ~= 'string' then
        return nil
    end

    local filename = type(entry.file) == 'string' and entry.file or record_filename(entry.id)
    local decoded = read_json(vim.fs.joinpath(root, 'contexts', filename))

    return type(decoded) == 'table' and decoded or nil
end

---Load persisted terminal metadata from disk.
---@param opts? { state_file?: string }
---@return terminalia.PersistencePayload
function M.load(opts)
    local path = state_file(opts and opts.state_file or nil)
    local root = state_dir(path)

    local decoded = read_json(path)

    if decoded == nil then
        return empty_payload()
    end

    if decoded.version ~= CURRENT_VERSION then
        return empty_payload()
    end

    local terminals = {}
    for index, item in ipairs(decoded.terminals or {}) do
        local restored = load_terminal_record(root, item, index)
        if restored ~= nil then
            table.insert(terminals, restored)
        end
    end

    local contexts = {}
    for _, item in ipairs(decoded.contexts or {}) do
        local restored = load_context_record(root, item)
        if restored ~= nil then
            table.insert(contexts, restored)
        end
    end

    return {
        next_id = tonumber(decoded.next_id) or 1,
        terminals = terminals,
        next_context_id = tonumber(decoded.next_context_id) or 1,
        current_context_id = type(decoded.current_context_id) == 'string' and decoded.current_context_id
            or 'context:host',
        contexts = contexts,
    }
end

---Persist terminal metadata to disk.
---@param payload terminalia.PersistencePayload
---@param opts? { state_file?: string }
function M.save(payload, opts)
    local path = state_file(opts and opts.state_file or nil)
    local root = state_dir(path)
    local persisted_terminals = vim.tbl_map(model.to_persisted_record, payload.terminals)
    local persisted_contexts = type(payload.contexts) == 'table' and payload.contexts or {}

    for _, terminal in ipairs(persisted_terminals) do
        write_json(record_path(root, 'terminals', terminal.id), terminal)
    end

    for _, context in ipairs(persisted_contexts) do
        write_json(record_path(root, 'contexts', context.id), context)
    end

    write_json(path, {
        version = CURRENT_VERSION,
        next_id = payload.next_id,
        next_context_id = payload.next_context_id,
        current_context_id = payload.current_context_id,
        terminals = vim.tbl_map(terminal_index_entry, persisted_terminals),
        contexts = vim.tbl_map(context_index_entry, persisted_contexts),
    })
end

---@param path string
function M.clear_path(path)
    if vim.fn.filereadable(path) == 1 then
        vim.fn.delete(path)
    end

    local root = state_dir(path)
    if root ~= '' and root ~= '/' and vim.fn.isdirectory(root) == 1 then
        vim.fn.delete(root, 'rf')
    end
end

---Delete the persisted state file if it exists.
function M.clear()
    M.clear_path(state_file())
end

return M

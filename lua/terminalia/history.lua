local config = require('terminalia.config')

local M = {}

---@type table<string, string>
local pending = {}

---@param id string
---@return string
function M.path(id)
    return vim.fs.joinpath(config.get().history_dir, string.format('%s.log', id))
end

---@return boolean
local function history_enabled()
    return config.get().persist_history == true
end

local function ensure_dir()
    vim.fn.mkdir(config.get().history_dir, 'p')
end

---@param id string
---@param lines string[]
local function append_lines(id, lines)
    if not history_enabled() or #lines == 0 then
        return
    end

    ensure_dir()
    vim.fn.writefile(lines, M.path(id), 'a')
end

---Append job callback chunks to durable history storage.
---@param id string
---@param data? string[]
function M.append_chunks(id, data)
    if not history_enabled() or data == nil or #data == 0 then
        return
    end

    local tail = pending[id] or ''
    local lines = {}

    for index, chunk in ipairs(data) do
        local value = chunk

        if index == 1 then
            value = tail .. value
        end

        if index == #data then
            pending[id] = value
        else
            table.insert(lines, value)
        end
    end

    append_lines(id, lines)
end

---Flush any in-memory tail fragment to durable history storage.
---@param id string
function M.flush(id)
    if not history_enabled() then
        pending[id] = nil
        return
    end

    local tail = pending[id]

    if tail and tail ~= '' then
        append_lines(id, { tail })
    end

    pending[id] = nil
end

---Return the current durable history lines for a terminal.
---@param id string
---@return string[]
function M.read_lines(id)
    local lines = {}

    if history_enabled() and vim.fn.filereadable(M.path(id)) == 1 then
        lines = vim.fn.readfile(M.path(id))
    end

    local tail = pending[id]

    if tail and tail ~= '' then
        table.insert(lines, tail)
    end

    return lines
end

---Return the current durable history as a newline-joined string snapshot.
---@param id string
---@return string
function M.read_text(id)
    return table.concat(M.read_lines(id), '\n')
end

---Delete a terminal's durable history and pending fragments.
---@param id string
function M.clear(id)
    pending[id] = nil

    if vim.fn.filereadable(M.path(id)) == 1 then
        vim.fn.delete(M.path(id))
    end
end

---Delete all durable history state.
function M.clear_all()
    pending = {}

    if vim.fn.isdirectory(config.get().history_dir) == 1 then
        vim.fn.delete(config.get().history_dir, 'rf')
    end
end

return M

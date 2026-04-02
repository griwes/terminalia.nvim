if vim.g.loaded_terminal_manager == 1 then
    return
end

vim.g.loaded_terminal_manager = 1

require('terminal_manager')

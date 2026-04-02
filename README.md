# terminal-manager.nvim

Native-feeling terminal objects for Neovim.

## Status

The current slice is intentionally small but usable:

- create named terminal records
- reveal a terminal in a split or float
- reopen an existing terminal by id during the session
- list registered terminals

Persistence, richer history, and integration layers are still planned work.

## Installation

Example local `lazy.nvim` spec:

```lua
{
    dir = vim.fn.expand('~/projects/neovim-plugin-orchestration/terminal-manager.nvim'),
    name = 'terminal-manager.nvim',
    opts = {
        default_view = 'split',
    },
}
```

## Commands

- `:TerminalManagerNew [name] [namespace] [view]`
- `:TerminalManagerOpen <id> [view]`
- `:TerminalManagerList`

Examples:

- `:TerminalManagerNew build workspace split`
- `:TerminalManagerNew scratch default float`
- `:TerminalManagerOpen terminal:1 float`

## Lua API

```lua
local terminal_manager = require('terminal_manager')

terminal_manager.setup({
    default_view = 'float',
})

local terminal = terminal_manager.api.create({
    name = 'build',
    namespace = 'workspace',
})

terminal_manager.api.open(terminal.id, { view = 'split' })
```

## Development

- `stylua .`
- `nvim --headless -u tests/minimal_init.lua -l tests/run.lua`

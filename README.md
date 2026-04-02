# terminal-manager.nvim

Native-feeling terminal objects for Neovim.

## Status

The current slice is intentionally small but usable:

- create named terminal records
- reveal a terminal in a split or float
- reopen an existing terminal by id during the session
- persist terminal metadata across setup/session restore
- update tracked cwd from OSC 7 terminal requests
- capture durable terminal history and open it in a separate scratch view
- expose a programmatic start/send/output/wait/kill/release control surface for downstream plugins
- restart exited terminals in place
- auto-prune disposable terminals after exit
- list registered terminals with cwd metadata

Deeper shell integration, picker layers, and adapter integrations are still planned work.

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
- `:TerminalManagerList [namespace] [cwd_prefix]`
- `:TerminalManagerHistory <id>`

Examples:

- `:TerminalManagerNew build workspace split`
- `:TerminalManagerNew scratch default float`
- `:TerminalManagerOpen terminal:1 float`
- `:TerminalManagerList workspace /tmp/workspace`
- `:TerminalManagerHistory terminal:1`

## Lua API

```lua
local terminal_manager = require('terminal_manager')

terminal_manager.setup({
    default_view = 'float',
    persist_terminals = true,
})

local terminal = terminal_manager.api.create({
    name = 'build',
    namespace = 'workspace',
})

terminal_manager.api.start(terminal.id)
print(vim.inspect(terminal_manager.api.output(terminal.id)))
terminal_manager.api.open(terminal.id, { view = 'split' })
terminal_manager.api.list({
    namespace = 'workspace',
    cwd_prefix = vim.fn.getcwd(),
})
terminal_manager.api.open_history(terminal.id)
```

Additional control helpers:

- `terminal_manager.api.start(id)`
- `terminal_manager.api.send(id, data)`
- `terminal_manager.api.output(id)`
- `terminal_manager.api.wait(id, timeout_ms)`
- `terminal_manager.api.kill(id)`
- `terminal_manager.api.release(id)`

## Development

- `stylua .`
- `nvim --headless -u tests/minimal_init.lua -l tests/run.lua`

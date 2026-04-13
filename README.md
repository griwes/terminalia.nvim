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
- expose concrete `TerminalContext` records plus current-context tracking for downstream terminal providers
- use one canonical `terminal-manager://...` URI family for live terminal buffers and terminal-history buffers
- reopen terminal/history URIs through registered context providers even when the encoded context stack is missing in memory
- contribute canonical terminal-URI reopen steps to `session.nvim` restore plans
- restart exited terminals in place while preserving named lowercase marks
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
- `:TerminalManagerOpenUri <uri> [view]`
- `:TerminalManagerOverseerCurrent`
- `:TerminalManagerOverseerUse <context_id>`
- `:TerminalManagerOverseerClear`

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

local remote = terminal_manager.api.create_child_context(terminal_manager.api.host_context().id, {
    kind = 'remote_workspace',
    label = 'devbox',
})

terminal_manager.api.set_current_context(remote.id)

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

- `terminal_manager.api.create_context(opts)`
- `terminal_manager.api.create_child_context(parent_id, opts)`
- `terminal_manager.api.host_context()`
- `terminal_manager.api.current_context()`
- `terminal_manager.api.set_current_context(id)`
- `terminal_manager.api.clear_current_context()`
- `terminal_manager.api.register_context_provider(kind, provider)`
- `terminal_manager.api.overseer_context([context_id])`
- `terminal_manager.api.set_overseer_context(id)`
- `terminal_manager.api.clear_overseer_context()`
- `terminal_manager.api.build_overseer_task(command, opts)`
- `terminal_manager.api.new_overseer_task(command, opts)`
- `terminal_manager.api.run_overseer_task(command, opts)`
- `terminal_manager.api.register_overseer_template(template)`
- `terminal_manager.api.decode_uri(uri)`
- `terminal_manager.api.open_uri(uri, opts)`
- `terminal_manager.api.start(id)`
- `terminal_manager.api.send(id, data)`
- `terminal_manager.api.output(id)`
- `terminal_manager.api.wait(id, timeout_ms)`
- `terminal_manager.api.kill(id)`
- `terminal_manager.api.release(id)`

## Development

- `stylua .`
- `nvim --headless -u tests/minimal_init.lua -l tests/run.lua`

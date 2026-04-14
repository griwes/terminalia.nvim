# Terminalia

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
- use one canonical `terminalia://...` URI family for live terminal buffers and terminal-history buffers
- reopen terminal/history URIs through registered context providers even when the encoded context stack is missing in memory
- contribute canonical terminal-URI reopen steps to `continuity.nvim` restore plans
- restart exited terminals in place while preserving named lowercase marks
- auto-prune disposable terminals after exit
- list registered terminals with cwd metadata

Deeper shell integration, picker layers, and adapter integrations are still planned work.

## Installation

Example local `lazy.nvim` spec:

```lua
{
    dir = vim.fn.expand('~/projects/neovim-plugin-orchestration/terminalia.nvim'),
    name = 'terminalia.nvim',
    opts = {
        default_view = 'split',
    },
}
```

## Commands

- `:TerminaliaNew [name] [namespace] [view]`
- `:TerminaliaOpen <id> [view]`
- `:TerminaliaList [namespace] [cwd_prefix]`
- `:TerminaliaHistory <id>`
- `:TerminaliaOpenUri <uri> [view]`
- `:TerminaliaOverseerCurrent`
- `:TerminaliaOverseerUse <context_id>`
- `:TerminaliaOverseerClear`

Examples:

- `:TerminaliaNew build workspace split`
- `:TerminaliaNew scratch default float`
- `:TerminaliaOpen terminal:1 float`
- `:TerminaliaList workspace /tmp/workspace`
- `:TerminaliaHistory terminal:1`

## Lua API

```lua
local terminalia = require('terminalia')

terminalia.setup({
    default_view = 'float',
    persist_terminals = true,
})

local remote = terminalia.api.create_child_context(terminalia.api.host_context().id, {
    kind = 'remote_workspace',
    label = 'devbox',
})

terminalia.api.set_current_context(remote.id)

local terminal = terminalia.api.create({
    name = 'build',
    namespace = 'workspace',
})

terminalia.api.start(terminal.id)
print(vim.inspect(terminalia.api.output(terminal.id)))
terminalia.api.open(terminal.id, { view = 'split' })
terminalia.api.list({
    namespace = 'workspace',
    cwd_prefix = vim.fn.getcwd(),
})
terminalia.api.open_history(terminal.id)
```

Additional control helpers:

- `terminalia.api.create_context(opts)`
- `terminalia.api.create_child_context(parent_id, opts)`
- `terminalia.api.host_context()`
- `terminalia.api.current_context()`
- `terminalia.api.set_current_context(id)`
- `terminalia.api.clear_current_context()`
- `terminalia.api.register_context_provider(kind, provider)`
- `terminalia.api.overseer_context([context_id])`
- `terminalia.api.set_overseer_context(id)`
- `terminalia.api.clear_overseer_context()`
- `terminalia.api.build_overseer_task(command, opts)`
- `terminalia.api.new_overseer_task(command, opts)`
- `terminalia.api.run_overseer_task(command, opts)`
- `terminalia.api.register_overseer_template(template)`
- `terminalia.api.decode_uri(uri)`
- `terminalia.api.open_uri(uri, opts)`
- `terminalia.api.start(id)`
- `terminalia.api.send(id, data)`
- `terminalia.api.output(id)`
- `terminalia.api.wait(id, timeout_ms)`
- `terminalia.api.kill(id)`
- `terminalia.api.release(id)`

## Development

- `stylua .`
- `nvim --headless -u tests/minimal_init.lua -l tests/run.lua`

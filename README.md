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
- plan and execute external editor file-open requests with `+cmd`, `--cmd`,
  `-d` diff mode, stdin buffers, and tab/current/split/vsplit/float/reuse
  open policies
- handle Terminalia-owned terminal OSC open actions without rendering the action
  markup into captured output
- define session-local editor shell functions for supported Terminalia-owned
  shells so `nvim file` and `$EDITOR file` open in the top-level Neovim
  without PATH shims
- export a parent Neovim RPC socket to Terminalia-owned terminal jobs so a real
  child `nvim file` process can redirect safe file-open invocations back to the
  top-level editor and exit

Deeper shell integration, picker layers, and adapter integrations are still planned work.

## Storage

Terminalia keeps `state_file` as a compact registry index and stores full
terminal/context records as separate JSON files under `state_file .. '.d'`.
Terminal output history remains separately owned by `history_dir`, one file per
terminal. Record and index replacements use same-directory temporary files and
atomic rename, so interrupted writes leave the previous file readable.

Continuity captures a bounded, immutable copy of the terminal records and their
context chains. It does not dereference Terminalia's mutable persistence files
during restore, and a captured record whose id has since been reused is restored
under a fresh id. Session-captured terminal buffers, including disposable ones,
are explicitly marked to restart; ordinary Terminalia persistence continues to
exclude disposable terminals.

## Requirements

- Neovim 0.11 or newer
- a POSIX shell for the built-in shell integration
- optional: `continuity.nvim`, `ministry.nvim`, and `overseer.nvim` for their
  respective integrations

Linux is the primary supported and CI-tested platform. The project is in early
development and currently publishes from `main`; tagged releases will define a
stable versioning policy when the API is ready for one.

## Installation

With `lazy.nvim`:

```lua
{
    'griwes/terminalia.nvim',
    opts = {
        default_view = 'split',
    },
}
```

Run `:checkhealth terminalia` after installation. See `:help terminalia` for
the command and API overview.

## Commands

- `:TerminaliaNew [name] [namespace] [view]`
- `:TerminaliaOpen <id> [view]`
- `:TerminaliaList [namespace] [cwd_prefix]`
- `:TerminaliaHistory <id>`
- `:TerminaliaOpenUri <uri> [view]`
- `:TerminaliaExternalOpen [nvim-style-file-args...]`
- `:TerminaliaOverseerCurrent`
- `:TerminaliaOverseerUse <context_id>`
- `:TerminaliaOverseerClear`

Examples:

- `:TerminaliaNew build workspace split`
- `:TerminaliaNew scratch default float`
- `:TerminaliaOpen terminal:1 float`
- `:TerminaliaList workspace /tmp/workspace`
- `:TerminaliaHistory terminal:1`
- `:TerminaliaExternalOpen +12 src/main.lua`
- `:TerminaliaExternalOpen --cmd "set number" -d left.txt right.txt`

## Terminal-Owned Open Actions

Processes running inside Terminalia terminals may request file opens by emitting
this private OSC sequence:

```text
ESC ] 777 ; terminalia ; open ; {"argv":["src/main.lua:12:1"]} BEL
```

The JSON payload accepts the same `argv`, `cwd`, `open_policy`, and `stdin_data`
shape as `terminalia.api.open_external()`. If `cwd` is omitted, Terminalia uses
the owning terminal record's current cwd. Terminalia's default handler rejects
payloads that would execute editor commands through `+cmd` or `--cmd`.

Provider plugins that own derived terminal contexts, such as Laboratory and
Consulate, should not duplicate the protocol machinery. They can produce open
actions through `terminalia.api.build_terminal_open_action()`, parse complete
sequences through `terminalia.api.parse_terminal_action_sequence()`, or parse
output streams through `terminalia.api.extract_terminal_action_chunks()`. That
lets a provider add metadata or path translations, handle the action itself, or
forward a modified payload into `terminalia.api.open_external()`. The
stream-safe stripping helper is also public so providers can keep action markup
out of their own captured output when they do not need the parsed actions.

When a terminal belongs to a derived `TerminalContext`, its context provider may
define `transform_terminal_action(context, action, terminal)`. Return a
rewritten action to let Terminalia continue with default handling, return
`false` when the provider handled the request itself, or return `nil` to keep
the original action.

Terminalia does not install a PATH shim or local wrapper for `nvim` here.
Provider-owned contexts should decide how their local, remote, or container
shells produce these sequences.

For host-owned interactive `sh`, `bash`, and `zsh` terminals, Terminalia
injects the producer side into only the shell session it launches. Terminalia
starts the interactive shell with a transient Terminalia-owned startup file that
loads the user's normal startup file first, then defines configured editor
commands such as `nvim`, `vim`, and `vi` before the prompt and line editor own
the terminal. It also exports `EDITOR` and `VISUAL` to a
self-contained shell command that emits the same host-open action, so child
tools that run `$EDITOR file` or `$VISUAL file` through a shell use the same
path. These session-local editor commands preserve blocking editor semantics:
the shell command waits until ordinary opened buffers are closed, and
CodeDiff-backed Git tool invocations wait until CodeDiff emits
`User CodeDiffClose` for the opened CodeDiff tabpage. It does not edit user rc/config files, add PATH entries, install helper
executables, make the target shell read startup input from a pipe, or send the
bootstrap as typed terminal input. Provider plugins can reuse the same snippet
through
`terminalia.api.build_terminal_open_shell_integration()` when they own a remote
or container launch path.

The same session-local hook also recognizes Git tool environment variables.
When Git launches a difftool with `LOCAL` and `REMOTE`, Terminalia includes that
metadata in the open action and, when `:CodeDiff` is available, opens
`CodeDiff file <local> <remote>` in the host. When Git launches a mergetool with
`MERGED`, Terminalia opens `CodeDiff merge <merged>`. If CodeDiff is not
available, Terminalia falls back to native diff windows for difftool launches
and a normal open of the merged file for mergetool launches. This behavior is
controlled by `external_git_tool_backend = 'auto'|'codediff'|'native'`. Wait
tokens are restricted to the transient startup directory for the
Terminalia-owned shell that emitted the action. Native Git-tool fallback
acknowledges immediately because Terminalia does not own a completion surface
for that UI.

As a fallback for descendant processes that launch a real child Neovim anyway,
Terminalia-owned terminal jobs also receive `TERMINALIA_PARENT_NVIM`,
`TERMINALIA_PARENT_KIND`, and `TERMINALIA_PARENT_OPEN_POLICY`. During
`require('terminalia').setup()`, a child Neovim that sees those variables will
connect to the parent RPC socket, ask the parent to open safe file targets
through `terminalia.api.open_external()`, and then exit. Missing or stale
sockets and non-file-open argv shapes fall back to normal child Neovim startup.
This path does not use a daemon, proxy, wrapper, PATH shim, or persistent shell
config.

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
print(vim.inspect(terminalia.api.output_lines(terminal.id)))
print(vim.inspect(terminalia.api.history_lines(terminal.id)))
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
- `terminalia.api.plan_external_open(argv, opts)`
- `terminalia.api.open_external(argv, opts)`
- `terminalia.api.build_terminal_open_action(payload)`
- `terminalia.api.parse_terminal_action_sequence(sequence)`
- `terminalia.api.parse_terminal_action(sequence)`
- `terminalia.api.new_terminal_action_strip_state()`
- `terminalia.api.strip_terminal_action_chunks(chunks, state)`
- `terminalia.api.extract_terminal_action_chunks(chunks, state)`
- `terminalia.api.build_terminal_open_shell_integration(opts)`
- `terminalia.api.start(id)`
- `terminalia.api.send(id, data)`
- `terminalia.api.output_lines(id)`
- `terminalia.api.history_lines(id)`
- `terminalia.api.output(id)`
- `terminalia.api.wait(id, timeout_ms)`
- `terminalia.api.kill(id)`
- `terminalia.api.release(id)`

## Development

- `stylua .`
- `nvim --headless -u tests/minimal_init.lua -l tests/run.lua`
- Broad spec: `tests/terminalia_spec.lua` (renamed from `tests/terminal_manager_spec.lua`)

## License

Apache-2.0. See [`LICENSE`](LICENSE).

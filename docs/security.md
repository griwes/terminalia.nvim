+# Terminalia Threat Model
+
+## Security boundary
+
+Terminalia manages terminal processes inside Neovim. It is an orchestration and
+presentation layer, not a sandbox. A command started by Terminalia has the same
+operating-system authority as Neovim unless the user supplies an external
+sandbox or lower-privilege execution context.
+
+Trusted inputs are the user's Neovim configuration, Terminalia configuration,
+registered context providers, and explicitly selected integration plugins.
+Terminal output and data emitted by child processes must be treated as
+untrusted. Persisted terminal records and URI buffers are local state, not
+authorization tokens.
+
+## Execution and extension points
+
+- Terminal commands, working directories, and environment variables are passed
+  to Neovim's terminal job facility. Terminalia does not validate a command's
+  intent.
+- Context providers can rewrite commands and terminal actions. A provider is
+  executable Neovim configuration and therefore belongs inside the trusted
+  boundary.
+- Shell integration creates temporary startup files and exports integration
+  variables to Terminalia-owned jobs. A child process can inspect its inherited
+  environment and can emit the integration protocol.
+- The optional parent-Neovim redirect exposes the parent RPC socket address to
+  child jobs. The redirect client accepts only file-open argument shapes and
+  rejects command/config/server flags, but another process able to access that
+  socket is not constrained by Terminalia's redirect client.
+
+## Terminal-output actions
+
+Terminalia recognizes its private OSC 777 open-action sequence only on owned
+terminal output. The normal external-open planner rejects editor command
+execution through `+cmd`, `--cmd`, and related passthrough forms. This
+reduces command injection through the protocol, but opening an attacker-chosen
+file can still invoke normal Neovim behavior such as configured autocommands,
+filetype plugins, or modeline handling.
+
+Git difftool and mergetool actions accept only their expected structured
+targets. If CodeDiff is installed and selected, Terminalia invokes CodeDiff's
+public command and trusts that plugin's behavior. The native fallback is also
+subject to the user's Neovim configuration.
+
+Wait tokens are accepted only beneath a launch-owned action directory, with a
+strict numeric basename, a real directory check, and exclusive file creation.
+This blocks direct path traversal and the covered symlink-directory escape.
+Users should still protect their runtime and temporary directories from other
+accounts.
+
+## Persistence and disclosure
+
+Terminal metadata and output history are persisted by default under Neovim's
+state directory. Output may contain source, command lines, credentials, or
+other sensitive data. Disable `persist_history` or `persist_terminals` for
+sensitive workflows and protect backups of the state directory. Terminal IDs
+are validated before being used as history filenames.
+
+## Operational guidance
+
+- Do not run untrusted commands merely because they appear in a Terminalia UI.
+- Disable editor shell integration or parent redirect when child processes
+  should not be able to request host-editor opens.
+- Treat third-party context providers and external-open handlers as code with
+  the same privileges as the rest of the Neovim configuration.
+- Use operating-system sandboxing, containers, or separate user accounts when
+  executing hostile workloads.
+


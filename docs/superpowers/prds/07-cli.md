# PRD 07 — CLI (`esr`)

**Spec reference:** §3.7 Management Surfaces, §8.2 Packaging
**E2E tracks:** every track exercises the CLI; A / B / E / F / G use it most heavily
**Plan phase:** Phase 7

---

## Goal

Ship the `esr` Python CLI that drives every user-facing interaction with a running esrd. Built on `click`, installed as `[project.scripts] esr` in `py/pyproject.toml`. All subcommands talk to the Elixir runtime via Phoenix channels (same transport as handlers/adapters, separate control topic `cli:<operation>/<uuid>`).

## Non-goals

- `esrd` Elixir escript (v0.1 can use the BEAM REPL for daemon ops; a dedicated `esrd` escript is v0.2)
- `esr install / talk / expose` Socialware verbs (v0.2)
- Rich TUI (use `click.echo` + tables via `rich.table` when a table helps)
- Interactive shell mode (`esr repl`) — v0.2

## Functional Requirements

### F01 — `esr use <host:port>`
`esr use localhost:4001` persists the target endpoint to `~/.esr/context` (YAML: `{endpoint: "ws://localhost:4001/adapter_hub/socket"}`). Env var `ESR_CONTEXT=host:port` overrides the file. `esr use` with no args prints the current context. **Unit test:** `py/tests/test_cli_use.py`.

### F02 — `esr status`
Prints an organisation-level view: installed counts, active actor count, active command count, dead-letter count, version. **Unit test:** `py/tests/test_cli_status.py` with a mocked runtime reply.

### F03 — `esr adapter install <source>`
Accepts local path, git URL, or Python package name. Workflow per spec §5.6:
1. Fetch source into `adapters/` (local copy; no global install)
2. Parse the `esr.toml` manifest
3. Invoke capability scan (`esr.verify.capability.scan_adapter`)
4. Register type in `~/.esrd/<instance>/adapters.yaml`
On failure, roll back the filesystem copy. **Unit test:** `py/tests/test_cli_adapter_install.py` — local path happy, capability violation fails, git URL clones.

### F04 — `esr adapter add <instance_name> --type <module> [--<key> <val> ...]`
Configures a new adapter instance. Flags map to the adapter's `AdapterConfig`. Written to `~/.esrd/<instance>/adapters.yaml`. Secrets (fields marked `secret=True` in the adapter manifest) go to `~/.esrd/<instance>/secrets/<adapter>.json` with `chmod 600`. **Unit test:** `py/tests/test_cli_adapter_add.py`.

### F05 — `esr adapter {list, list --instances, remove}`
List types; list instances; remove type (fails if instances exist). **Unit test:** all three variants.

### F06 — `esr handler install <source>`
Parallel to adapter install. Invokes `esr.verify.purity.scan_imports` for the import allow-list check. Registers under `~/.esrd/<instance>/handlers.yaml`. **Unit test:** `py/tests/test_cli_handler_install.py`.

### F07 — `esr handler {list, remove}`
Straightforward. **Unit test:** both.

### F08 — `esr cmd install <source>`
Parallel. Imports the source module (registers the `@command`), resolves dependencies (referenced adapters + handlers must already be installed), calls `compile_topology` + writes `patterns/.compiled/<name>.yaml`. Failure with actionable message on missing dep per spec §6.8. **Unit test:** `py/tests/test_cli_cmd_install.py` — happy + missing-dep.

### F09 — `esr cmd {list, show <name>, uninstall <name>, upgrade <name>}`
`list` scans the registry; `show` pretty-prints the compiled topology; `uninstall` removes but fails if instances are running; `upgrade` re-runs install with replace semantics. **Unit test:** each.

### F10 — `esr cmd compile <name>`
Compiles the pattern from source (without installing). Writes to `.compiled/<name>.yaml`. Useful for CI / pre-commit hooks. **Unit test:** `py/tests/test_cli_cmd_compile.py`.

### F11 — `esr cmd run <name> [--param k=v ...]`
Loads `.compiled/<name>.yaml`, substitutes params, sends to the runtime for instantiation via a `cli:run` control topic. Returns the instantiation handle on stdout. Timeout 30 s; on timeout, prints a helpful error. **Unit test:** `py/tests/test_cli_cmd_run.py` — mocked runtime reply.

### F12 — `esr cmd stop <name> --param k=v ...`
Deactivates a running instantiation by (name, params). Cascade tear-down per §6.5. **Unit test:** `py/tests/test_cli_cmd_stop.py`.

### F13 — `esr cmd restart <name> --param k=v ...`
Stops + runs with same params, preserving Elixir-side state (the PeerServers are torn down and respawned; the state in ETS-persistence survives). **Unit test:** `py/tests/test_cli_cmd_restart.py`.

### F14 — `esr-lint <path>`
Standalone purity linter (installed as a separate entry point or `esr lint <path>`). Scans `.py` files in the given directory, runs Checks 1 (imports) and 2 (decorator presence for handlers) plus adapter capability scan. Exits nonzero on any violation. Used in CI and as a pre-commit hook. **Unit test:** `py/tests/test_cli_lint.py`.

### F15 — `esr actors {list, tree, inspect <id>, logs <id> [--follow]}`
Queries via `cli:actors` control topic. `list` → table (id, type, handler, uptime). `tree` → DAG visualisation (ASCII art or `rich.tree`). `inspect` → JSON dump of state. `logs` tails per-actor log via a streaming channel. **Unit test:** each.

### F16 — `esr trace [--session <id>] [--last <duration>] [--filter <pattern>]`
Queries `Esr.Telemetry.Buffer` via `cli:trace` topic. Returns time-ordered causal chain. `--filter` supports event globs (`esr.handler.*`). Output is JSON lines unless `--format table`. **Unit test:** `py/tests/test_cli_trace.py`.

### F17 — `esr telemetry subscribe <pattern> [--format json|table]`
Opens a subscription to live telemetry. Prints each matching event to stdout. Ctrl-C terminates the subscription cleanly. **Unit test:** `py/tests/test_cli_telemetry.py` — verify subscription contract + clean shutdown.

### F18 — `esr debug {replay <msg_id>, inject --to <actor_id> --event <json>, pause <actor_id>, resume <actor_id>}`
All go through `cli:debug` topic and hit dedicated runtime endpoints. Each operation fails clearly if the target doesn't exist. **Unit test:** each debug op.

### F19 — `esr deadletter {list, retry <entry_id>, flush}`
Queries the dead-letter queue; retry re-pushes a single entry to its original target; flush empties the queue (with confirmation prompt). **Unit test:** each.

### F20 — `esr scenario run <name> [--verbose]`
Runs a scenario YAML file from `scenarios/`. The runner parses the YAML (setup / steps / acceptance assertions), invokes other CLI commands per step, verifies assertions, produces a pass/fail report per track. Used to run the E2E. **Unit test:** `py/tests/test_cli_scenario.py` — with a minimal fake scenario.

### F21 — `esr drain [--timeout <duration>]`
Gracefully stops all running commands in dependency order. Blocks until complete or timeout. **Unit test:** `py/tests/test_cli_drain.py`.

### F22 — Error UX
Every CLI command:
- Exits 0 on success with minimal output (respect script-ability)
- Exits nonzero with a human-readable error on failure, plus a suggestion when obvious (e.g. "run `esr use` first" if no context is set)
- Supports `--verbose` / `-v` for debug-level logging to stderr
- Supports `--json` where a structured output is useful
**Unit test:** `py/tests/test_cli_error_ux.py` — verify exit codes, stderr format.

### F23 — CLI doesn't require runtime for read-only ops
`esr adapter list`, `esr handler list`, `esr cmd list`, and `esr cmd show` work off the local filesystem alone (no runtime connection needed). `esr status`, `esr actors list`, `esr trace` etc. all require a running runtime. **Unit test:** `py/tests/test_cli_offline.py`.

## Non-functional Requirements

- `esr <any-subcommand> --help` prints < 300 ms (measures startup)
- `esr <read-only-op>` returns in < 100 ms cold
- Operations that talk to runtime complete in < 500 ms p95 (network + RPC)

## Dependencies

- PRD 02 (SDK) for all decorator imports
- PRD 03 (IPC channel client) for runtime communication
- PRDs 04 / 05 / 06 for anything the CLI installs

## Unit-test matrix

| FR | Test file | Test name |
|---|---|---|
| F01 | `py/tests/test_cli_use.py` | set / read / env override |
| F02 | `py/tests/test_cli_status.py` | status display |
| F03 | `py/tests/test_cli_adapter_install.py` | local / git / fail |
| F04 | `py/tests/test_cli_adapter_add.py` | instance config |
| F05 | `py/tests/test_cli_adapter.py` | list / remove |
| F06 | `py/tests/test_cli_handler_install.py` | handler install |
| F07 | `py/tests/test_cli_handler.py` | list / remove |
| F08 | `py/tests/test_cli_cmd_install.py` | install / missing dep |
| F09 | `py/tests/test_cli_cmd.py` | list / show / upgrade / uninstall |
| F10 | `py/tests/test_cli_cmd_compile.py` | compile |
| F11 | `py/tests/test_cli_cmd_run.py` | run |
| F12 | `py/tests/test_cli_cmd_stop.py` | stop |
| F13 | `py/tests/test_cli_cmd_restart.py` | restart preserves state |
| F14 | `py/tests/test_cli_lint.py` | lint |
| F15 | `py/tests/test_cli_actors.py` | list / tree / inspect / logs |
| F16 | `py/tests/test_cli_trace.py` | trace |
| F17 | `py/tests/test_cli_telemetry.py` | subscribe |
| F18 | `py/tests/test_cli_debug.py` | replay / inject / pause / resume |
| F19 | `py/tests/test_cli_deadletter.py` | list / retry / flush |
| F20 | `py/tests/test_cli_scenario.py` | run |
| F21 | `py/tests/test_cli_drain.py` | drain |
| F22 | `py/tests/test_cli_error_ux.py` | error UX |
| F23 | `py/tests/test_cli_offline.py` | read-only offline |

## Acceptance

- [ ] All 23 FRs have passing unit tests
- [ ] `esr --help` and every subcommand `--help` render complete docs
- [ ] Shell tab-completion installed for bash / zsh via click-completion (post-install step documented in README)
- [ ] Integration: running the full E2E scenario via `esr scenario run e2e-platform-validation` exercises every CLI path mentioned in the tracks

---

*End of PRD 07.*

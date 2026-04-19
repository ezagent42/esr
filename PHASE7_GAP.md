# Phase 7 CLI Gap Analysis

Audit performed: iter 46, 2026-04-20.

## Covered (read-only, 12/23)

| FR | Test | Command |
|---|---|---|
| F01 | test_cli_use.py | `esr use <host:port>` |
| F03 | test_cli_install.py | `esr adapter install <source>` |
| F04 | test_cli_adapter_add.py | `esr adapter add <name> --type ...` |
| F05 | test_cli_list.py | `esr adapter list` / remove |
| F06 | test_cli_install.py | `esr handler install <source>` |
| F07 | test_cli_list.py | `esr handler list` / remove |
| F08 | test_cli_cmd_install.py | `esr cmd install <source>` |
| F09 | test_cli_list.py + test_cli_cmd_show.py | `esr cmd list/show/uninstall/upgrade` |
| F10 | test_cli_cmd_compile.py | `esr cmd compile <name>` |
| F14 | test_cli_lint.py | `esr-lint <path>` |
| F22 | test_cli_error_ux.py | error UX |
| F23 | test_cli_offline.py | read-only offline |

## Missing (runtime-dependent, 11/23)

| FR | Test (missing) | Command (missing) | Notes |
|---|---|---|---|
| F02 | test_cli_status.py | `esr status` | Query runtime for basic health |
| F11 | test_cli_cmd_run.py | `esr cmd run <name> [--param k=v]` | Triggers Topology.Instantiator |
| F12 | test_cli_cmd_stop.py | `esr cmd stop <name>` | Triggers Topology.Registry.deactivate |
| F13 | test_cli_cmd_restart.py | `esr cmd restart <name>` | Stop + start preserving state |
| F15 | test_cli_actors.py | `esr actors list/tree/inspect/logs` | Read PeerRegistry via HTTP |
| F16 | test_cli_trace.py | `esr trace [--session] [--last]` | Read telemetry buffer |
| F17 | test_cli_telemetry.py | `esr telemetry subscribe <pattern>` | Long-running stream |
| F18 | test_cli_debug.py | `esr debug {replay, inject, pause, resume}` | Adapter ops |
| F19 | test_cli_deadletter.py | `esr deadletter list/retry/flush` | Query DeadLetter |
| F20 | test_cli_scenario.py | `esr scenario run <name>` | Kick off E2E track |
| F21 | test_cli_drain.py | `esr drain [--timeout]` | Graceful shutdown |

## Implementation Strategy

All 11 missing commands talk to the Elixir runtime. Two approaches:

1. **Mocked tests** — unit tests mock the WebSocket / HTTP call and verify only CLI parsing + output formatting. Doesn't cover the live integration but validates the command surface. Each FR → ~30 lines of test + ~40 lines of CLI code.

2. **Live-gated tests** — skipif(ESR_E2E_RUNTIME != "1"). Cover exactly the round-trip but need a running Phoenix. Similar to how F13 IPC was handled.

**Recommendation:** combo — mocked tests for CLI layer (parsing, output) + live-gated tests for integration. This mirrors the PRD-level split: each command gets a unit test that runs in CI without the runtime, plus a live-gated integration test.

For ralph-loop time budget, prioritise mocked unit tests to close the matrix; live-gated tests can land during Phase 8 E2E work.

## Order of implementation

1. **F02 status** — simplest, mostly formatting (next iter).
2. **F20 scenario run** — PRD 08 E2E depends on it; gate higher.
3. **F11 cmd run, F12 stop, F13 restart** — related, share code paths.
4. **F19 deadletter, F16 trace, F17 telemetry** — read-only queries.
5. **F15 actors, F18 debug** — richest commands; biggest per-FR.
6. **F21 drain** — last.

Each FR remains "one test, one implementation, one commit" per ralph-loop discipline.

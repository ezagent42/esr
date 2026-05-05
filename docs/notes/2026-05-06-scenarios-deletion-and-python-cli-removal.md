# scenarios/ deletion + Python CLI removal (2026-05-06)

**Goal:** Remove the two yaml-driven `scenarios/*.yaml` fossils + the
yaml-runner Python entry-point + the rest of `py/src/esr/cli/`. Land
the 3 unit-test gaps that the previous PR (cli-channel→slash
migration) left for the new `Esr.Commands.{Deadletter,Debug,Trace}`
modules. Replace `final_gate.sh:56`'s `esr scenario run` with a
working `tests/e2e/` script.

## Why

After the cli-channel→slash migration, `runtime/lib/esr_web/cli_channel.ex`
is a 30-line shell — every former handler returns `unknown_topic`.
Python CLI commands that used to talk to the runtime via the
`cli:*` Phoenix.Channel topic now all hit that fallback, i.e. the
Python CLI is functionally neutered. The only blocker that kept the
Python CLI alive was `esr scenario run`, used by `final_gate.sh:56`
to execute `scenarios/e2e-esr-channel.yaml`.

Audit revealed those yaml scenarios are fossils:

  - Both reference the **dead** v0.1 topology pattern
    (`feishu-thread-session` / `feishu-app-session`)
  - Every step's primary verb is `esr cmd run/stop/drain` — these
    were P3-13 deleted with `Esr.Topology`
  - Last touched 2026-05-02, but they stopped working when topology
    was deleted earlier in the cycle
  - The pre-existing `tests/e2e/scenarios/01-11_*.sh` (PR-7+ era)
    already covers the Feishu→CC business logic against the LIVE
    architecture

`final_gate.sh:56`'s call has been silently producing a `fail=1`
flag without breaking the gate (the `if !` only sets a marker; L0+
does the real live assertions afterwards).

## Coverage audit — yaml scenarios vs tests/e2e/

| yaml capability | covered by | status |
|---|---|---|
| spawn session (A) | `01_single_user_create_and_end.sh` (`/new-session`) | ✅ preserved |
| concurrent sessions (B/D) | `02_two_users_concurrent.sh` | ✅ preserved |
| actors list (C) | `01_*.sh` (implicit) | ✅ preserved |
| @-addressing (D) | PR-21l replaced with chat-current-slot | 🟢 obsoleted, drop |
| session_killed broadcast (E) | `01_*.sh` user-step 6 (`/end-session`) | ✅ preserved |
| cross-app routing | `04_multi_app_routing.sh` | ✅ preserved |
| topology / reachable_set | `05_topology_routing.sh` | ✅ preserved |
| PTY attach + bidir | `06_pty_attach.sh` / `07_pty_bidir.sh` | ✅ preserved |
| `esr trace` (E) | **no e2e or unit test** | 🔴 gap — fix in PR |
| `esr deadletter list/flush` (H) | **no e2e or unit test** | 🔴 gap — fix in PR |
| `esr debug pause/resume` (G) | **no e2e or unit test** | 🔴 gap — fix in PR |
| `esr drain` (F) | concept dead post-P3-13, replaced by per-session `/end-session` | 🟢 dropped |

The 3 real gaps land as ExUnit unit tests in this PR — they're
slash-command-level coverage, not Feishu→CC business-logic.

## Scope of this PR

  - **Delete** `scenarios/` (the yaml + the Python `esr scenario`
    sub-command path)
  - **Delete** `py/src/esr/cli/` entirely
  - **Delete** the `[project.scripts] esr = ...` entry-point in
    `py/pyproject.toml`
  - **Audit + selective delete** of `py/src/esr/*` non-cli modules
    (`workspaces.py`, `command.py`, etc.) — drop only those with
    zero remaining callers after `cli/` is gone
  - **Add** 3 ExUnit modules:
    `runtime/test/esr/commands/deadletter_test.exs`,
    `debug_test.exs`,
    `trace_test.exs`
  - **Update** `final_gate.sh:56` to call a live `tests/e2e/` script
    (likely `08_plugin_core_only.sh` — fast, exercises the
    plugin-loader core path)

## Out of scope

  - Porting yaml's "drain" semantics — `/end-session` per session
    is the replacement, no global drain command planned
  - Retiring `tests/e2e/` — separate concern
  - Changes to `tests/e2e/fixtures/probe_file.txt` — keep, used by
    `01_*.sh`'s `send_file` user-step

## Order of work

1. Field note (this file) + branch (already created).
2. **Commit 2**: `runtime/test/esr/commands/deadletter_test.exs` —
   unit tests for `Esr.Commands.Deadletter.{List,Flush}`. Direct
   `execute/1` invocation; verify list shape + flush count.
3. **Commit 3**: `runtime/test/esr/commands/debug_test.exs` — unit
   tests for `Esr.Commands.Debug.{Pause,Resume}`. Spawn a real
   `Esr.Entity.Server` via `start_supervised`, exercise pause →
   `paused=true` and resume → `paused=false`.
4. **Commit 4**: `runtime/test/esr/commands/trace_test.exs` — unit
   tests for `Esr.Commands.Trace`. Seed
   `Esr.Telemetry.Buffer.record/4` with one event, assert the
   command surfaces it.
5. **Commit 5**: delete `scenarios/` directory wholesale.
6. **Commit 6**: `final_gate.sh:56` swap to a live `tests/e2e/`
   invocation; note in commit message which script + why.
7. **Commit 7**: delete `py/src/esr/cli/` + `py/pyproject.toml`
   entry-point edit.
8. **Commit 8**: audit + delete unused `py/src/esr/*` modules.
9. **Commit 9**: any compile/test fixes surfaced by 5–8.
10. mix test full + bash e2e smoke run + subagent code-reviewer
    pass + open PR.

## Lessons feeding back

- **"6 months" was a hallucination** I introduced by quoting the
  cli-channel migration field note's text without checking git log.
  Project is ~3 weeks old. Memory rule candidate: when reasoning
  about timelines, verify against `git log` before asserting.
- **The previous PR shipped 3 new slash commands without unit
  tests.** The subagent code-reviewer didn't flag missing-test as
  an issue — it focused on behavior preservation and security
  boundaries. For new modules added during a migration, the
  reviewer prompt should explicitly check unit-test coverage.

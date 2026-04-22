# PR-1 Progress Snapshot

**Date**: 2026-04-22 (merged)
**Branch**: `feature/peer-session-refactor` (synced to `origin/main`)
**Squash-merge commit**: `155bc56` (on `main`)
**Status**: merged ✅

---

## New public API surfaces

### `Esr.Peer` (lib/esr/peer.ex)
- `@callback peer_kind() :: :proxy | :stateful`
- `use Esr.Peer, kind: :proxy | :stateful` — injected by Proxy/Stateful

### `Esr.Peer.Proxy` (lib/esr/peer/proxy.ex)
- `@callback forward(msg, ctx) :: :ok | {:drop, reason}`
- Compile-time rejection of `handle_call/3` and `handle_cast/2` via `@before_compile` + `Module.definitions_in/2`
- `raise CompileError, description: msg` (not `file:`/`line:` — those aren't public API)

### `Esr.Peer.Stateful` (lib/esr/peer/stateful.ex)
- `@callback init(peer_args :: map()) :: {:ok, state} | {:stop, reason}`
- `@callback handle_upstream(msg, state) :: {:forward, [term], state} | {:reply, term, state} | {:drop, atom, state}`
- `@callback handle_downstream(msg, state) :: {:forward, [term], state} | {:drop, atom, state}`

### `Esr.OSProcess` (lib/esr/os_process.ex, 191 lines)
- `@callback os_cmd(state) :: [String.t()]`
- `@callback os_env(state) :: [{String.t(), String.t()}]`
- `@callback on_os_exit(status, state) :: {:stop, reason} | {:restart, new_state}`
- `use Esr.OSProcess, kind: :atom, wrapper: :muontrap | :none`
  - `:muontrap` (default): runs under `MuonTrap.muontrap_path()` wrapper with `--delay-to-sigkill 5000 --capture-output`; kernel-level cleanup guaranteed; stdin NOT writable (muontrap consumes stdin as ack channel)
  - `:none`: plain `Port.open`; stdin/stdout both usable via `Port.command/2` and `{:line, N}` option; cleanup requires app-level handshake (terminate/2, child-side EOF detection)
- Worker `OSProcessWorker` injected by macro; exposes `os_pid/1`, `write_stdin/2`
- Dispatches stdout lines to parent Peer as `handle_upstream({:os_stdout, line}, state)`

### `Esr.TmuxProcess` (lib/esr/tmux_process.ex, 128 lines)
- `use Esr.Peer.Stateful` + `use Esr.OSProcess, kind: :tmux, wrapper: :none`
- `start_link(%{session_name:, dir:, subscriber: pid})`
- `send_command(pid, cmd)` — writes tmux control-protocol command
- `send_keys(pid, session, keys)` — convenience
- Parser for tmux `-C` control protocol: `%begin time num flags`, `%end ...`, `%output %pane bytes`, `%exit`
- Cleanup: `terminate/2` sends `kill-session -t <name>` before shutdown
- `os_cmd` deliberately OMITS `-d` flag (plan had `-d` but control-mode `-d` causes immediate `%exit`; keep session attached)

### `Esr.PyProcess` (lib/esr/py_process.ex, 90 lines)
- `use Esr.Peer.Stateful` + `use Esr.OSProcess, kind: :python, wrapper: :none`
- `start_link(%{entry_point: {:module | :script, ...}, subscriber: pid})`
- `send_request(pid, %{id:, payload:})` — encodes JSON line + `\n`
- `os_cmd/1`: `{:module, m}` → `["uv", "run", "python", "-m", m]`; `{:script, p}` → `["uv", "run", "python", p]`
- `os_env/1`: `[{"PYTHONUNBUFFERED", "1"}]`
- `handle_upstream({:os_stdout, line}, state)` parses JSON, forwards to subscribers as `{:py_reply, decoded_map}`
- Invalid JSON lines `{:drop, :py_parse_error, state}` (non-fatal)
- Cleanup: Python detects stdin EOF when BEAM closes the Port, exits cleanly (~120ms observed)

### `Esr.SessionSocketRegistry` (lib/esr/session_socket_registry.ex — renamed from old `Esr.SessionRegistry`)
- Same functions as before (`register/2`, `mark_offline/1`, `lookup/1`, `list/0`, `notify_session/2`)
- No functional change; only module name differs

### `Esr.SessionRegistry` (new, lib/esr/session_registry.ex, 132 lines)
- `load_agents(path)` — parses `agents.yaml`, compiles agent defs
- `agent_def(name) :: {:ok, def} | {:error, :not_found}`
- `register_session(session_id, %{chat_id:, thread_id:}, peer_refs)`
- `lookup_by_chat_thread(chat_id, thread_id) :: {:ok, session_id, peer_refs} | :not_found`
- `unregister_session(session_id)`
- Logs WARN for reserved fields (`rate_limits`, `timeout_ms`, `allowed_principals`)
- Started as supervised singleton in `Esr.Application`

### `Esr.PeerFactory` (lib/esr/peer_factory.ex, 49 lines)
- `spawn_peer(session_id, mod, args, neighbors, ctx) :: {:ok, pid} | {:error, reason}`
- `terminate_peer(session_id, pid) :: :ok`
- `restart_peer(session_id, spec) :: {:ok, pid}`
- Session-supervisor resolution: `Process.get(:peer_factory_sup_override, Esr.Session.supervisor_name(session_id))` — test-time override via process dict; production path uses `Esr.Session.supervisor_name/1` (introduced P2-6)
- Strict public surface: **ONLY** these three functions; surface stability test enforces

### `Esr.PeerPool` (lib/esr/peer_pool.ex, 83 lines)
- `default_max_workers() == 128`
- `start_link(name:, worker:, max: N)`
- `acquire(pool, opts) :: {:ok, pid} | {:error, :pool_exhausted}`
- `release(pool, pid) :: :ok`
- Monitor-DOWN cleanup for crashed workers
- Waiter queue with configurable timeout

---

## Decisions locked in during PR-1

**D1-PR1-a: `Esr.OSProcess` supports two wrapper modes (`:muontrap` and `:none`)**, not a single mode. Discovered empirically in P1-6 that MuonTrap 1.7's wrapper binary cannot support stdin-write + stdout-read + cleanup simultaneously (stdin is consumed as ack channel when `--capture-output` is enabled). All interactive peers (Tmux, Python) use `:none` + app-level cleanup. See `docs/notes/muontrap-mode3-constraint.md`.

**D1-PR1-b: `MuonTrap.muontrap_path/0` is the only API to locate the wrapper binary.** `:code.priv_dir(:muontrap)` is an internal detail that has changed between releases. See `.claude/skills/muontrap-elixir/SKILL.md`.

**D1-PR1-c: `Peer.Proxy` compile-time callback rejection uses `@before_compile` + `Module.definitions_in(env.module, :def)`.** `raise CompileError` takes only `description:` as public keyword arg (not `file:`/`line:`).

**D1-PR1-d: Integration tests tagged `:integration`; `ExUnit.start(exclude: [:integration])` skips by default.** Runs explicitly via `mix test --only integration`.

**D1-PR1-e: `PeerFactory.spawn_peer/5` first arg is `session_id` (not `supervisor_pid`).** Resolution to supervisor happens inside via `Esr.Session.supervisor_name/1` (P2-6). Tests use `:peer_factory_sup_override` process-dict scaffold until P2-6 removes it.

**D1-PR1-f: `PeerPool.acquire/2` GenServer.call timeout = user_timeout + 1s buffer** — so the server-side `{:error, :pool_exhausted}` reply can arrive before the outer call aborts. The public-facing `timeout` still controls the pool's wait budget; the +1s is internal plumbing.

---

## Tests added (13 new test files, 5 integration)

Unit tests (run by default):
- `test/esr/peer_test.exs` — 2 tests
- `test/esr/peer/proxy_compile_test.exs` — 3 tests
- `test/esr/peer/stateful_test.exs` — 4 tests
- `test/esr/session_registry_test.exs` — 4 tests
- `test/esr/peer_factory_test.exs` — 3 tests
- `test/esr/peer_pool_test.exs` — 3 tests

Integration tests (opt-in via `--only integration`):
- `test/esr/os_process_test.exs` — 2 tests (os_pid fetch, cleanup-within-10s via SleepPeer)
- `test/esr/tmux_process_test.exs` — 1 test (control-mode events)
- `test/esr/py_process_test.exs` — 2 tests (JSON round-trip, cleanup)

Totals: **339 tests + 5 integration = 344 covered**. Known-flake tests from PR-0/PR #11 (`peer_server_lane_b_test:188`, `cap_test:149`) may fire intermittently; confirmed not caused by PR-1 work.

---

## Tech debt introduced (to be resolved in later PRs)

| Item | Introduced | Resolved |
|---|---|---|
| `:peer_factory_sup_override` process-dict scaffold in `PeerFactory` | P1-10 | P2-6 (after `Esr.Session.supervisor_name/1` exists) |
| `PeerProxy` has no capability-check wrapper | P1-2 | P2-4 (extend `Peer.Proxy` macro with `@required_cap`) |
| `SessionRegistry` has no consumers yet (test-only) | P1-9 | P2-2..P2-4 (FeishuAppAdapter, FeishuChatProxy, FeishuAppProxy consume it) |
| No `AdminSession` bootstrap — `PeerFactory` can't spawn admin-scope peers | — | P2-1 (introduces `spawn_peer_bootstrap/4`) |

---

## Next PR (PR-2) expansion inputs

When expanding the PR-2 outline into bite-sized steps, the session needs:

- This snapshot (load first for API shapes)
- Spec v3.1 `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` §3.4, §3.5, §4.1, §5.1, §5.3
- Plan's PR-2 outline
- PR-1 code: `runtime/lib/esr/peer.ex`, `peer/proxy.ex`, `peer/stateful.ex`, `session_registry.ex`, `peer_factory.ex` (consumers' API shape)
- `runtime/lib/esr_web/feishu_controller.ex` (or equivalent — find the current Feishu webhook entry to retarget)
- `runtime/lib/esr/peer_server.ex` — current Feishu handling to migrate away from

Key PR-2 open questions:
1. **FeishuAppAdapter owns the WS?** Today `MsgBotClient` is spawned elsewhere (check `runtime/lib/esr/` for who currently holds the Feishu WS). PR-2 should consolidate: AdminSession's FeishuAppAdapter owns exactly one WS connection per app_id.
2. **`Peer.Proxy` capability-check wrapper shape**: does `@required_cap` accept a template (e.g. `"workspace:${session.workspace_name}/msg.send"`) that resolves at spawn time, or only literals? Spec §3.6 leans toward literals; revisit when implementing.
3. **`Esr.Session.supervisor_name/1`**: for `session_id == "admin"`, return `Esr.AdminSession.ChildrenSupervisor` (or similar); for ULIDs, return via `{:via, Registry, ...}`. Verify boot order: Registry → AdminSession → SessionsSupervisor → user sessions.
4. **SlashHandler is in AdminSession (single, global)** per spec §3.4. How does FeishuChatProxy find it? SessionRegistry has a fixed entry `"admin::slash_handler"` that resolves to the SlashHandler pid — this is the "slash fallback" exception from spec §3.6.

PR-2 subagent will verify these before coding.

---

## Links

- PR #12 (squash-merged): https://github.com/ezagent42/esr/pull/12
- Spec: `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md`
- Plan: `docs/superpowers/plans/2026-04-22-peer-session-refactor-implementation.md`
- Notes (new): `docs/notes/`

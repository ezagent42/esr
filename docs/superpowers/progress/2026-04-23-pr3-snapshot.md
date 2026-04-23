# PR-3 Progress Snapshot

**Date**: 2026-04-23 (merged)
**Branch**: `feature/peer-session-refactor` (synced to `origin/main`)
**Squash-merge commit**: `a416a25` (on `main`)
**Status**: merged ✅

---

## New public API surfaces

### `Esr.Peers.CCProxy` (lib/esr/peers/cc_proxy.ex)
- `Peer.Proxy` with `@required_cap "peer_proxy:cc/forward"` (canonical form)
- Forwards session-local requests to CCProcess

### `Esr.Peers.CCProcess` (lib/esr/peers/cc_process.ex)
- `Peer.Stateful`; invokes HandlerRouter for tool calls
- Sends `{:send_input, text}` downstream to TmuxProcess
- Receives `{:tmux_output, bytes}` upstream

### `Esr.Peers.TmuxProcess` (lib/esr/peers/tmux_process.ex — moved from `lib/esr/`)
- `Peer.Stateful` + `Esr.OSProcess, wrapper: :pty`
- Parses tmux `-C` control protocol: `%begin`, `%end`, `%output`, `%exit`
- `terminate/2` issues `tmux kill-session -t <name>` before shutdown

### `Esr.Capabilities.has_all?/2` (lib/esr/capabilities.ex)
- New helper: `has_all?(principal_id, [perms]) :: :ok | {:missing, [perms]}`
- Used by `Session.New` to validate agent's capabilities_required before spawning

### `Esr.Admin.Commands.Session.New` (renamed)
- Per D15: now the AGENT-SESSION command (not branch-worktree)
- Legacy branch-worktree command moved to `Session.BranchNew`
- Dispatcher `session_new` kind → Session.New (agent); `session_branch_new` → BranchNew
- Verifies `capabilities_required` via `Esr.Capabilities.has_all?/2`

### `Esr.Admin.Commands.Session.End` (agent-aware)
- Legacy branch-end moved to `Session.BranchEnd`
- `session_end` kind now tears down agent sessions via SessionRouter

### `Esr.SessionRouter` (lib/esr/session_router.ex)
- Control-plane GenServer
- Accepts: `:create_session_sync`, `:end_session_sync`, `:new_chat_thread`, `:agents_yaml_reloaded`
- Risk-E guard: `handle_info`/`handle_call` catch-all drops + WARN, never crashes
- Spawns peer chains via `PeerFactory.spawn_peer/5` for each declared pipeline module

### `Esr.OSProcess` (rewritten — now erlexec-backed)
- `wrapper: :pty | :plain` option (replaced `:muontrap | :none`)
- Uses `:exec.run_link/2` + `:exec.send/2` + `:exec.stop/1`
- Resolves the "stdin write + stdout read + BEAM-exit cleanup" trilemma that MuonTrap couldn't
- Handles `{:stdout, os_pid, bytes}`, `{:DOWN, os_pid, :process, pid, reason}` messages

### `Esr.SessionProcess.grants` (filled in by P3-3a)
- Per-session grants projection: init pulls principal's grants from `Grants` → local map
- Subscribes to `grants:<principal_id>` PubSub topic; refreshes on `{:grants_changed}`
- `SessionProcess.has?/2` reads local map (no ETS hit on hot path)
- Peers migrate from `Grants.has?` to `SessionProcess.has?` per `proxy_ctx.session_process_pid`

---

## Decisions locked in during PR-3

**D3-PR3-a: Switched底座 from Port+muontrap to erlexec.** Rationale: erlexec resolves the Mode 3 trilemma via native PTY + bidirectional I/O + `exec-port` BEAM-exit cleanup. See `docs/notes/erlexec-migration.md`.

**D3-PR3-b: Capability names canonicalized to `prefix:name/perm` shape.** `cap.*` dotted form doesn't match `Grants.matches?/2` parser. Updated spec §3.5/§3.6/§1.8 + agents.yaml fixtures + all `@required_cap` strings.

**D3-PR3-c: `Session.New` is now the agent-session command.** Legacy branch-worktree moved to `Session.BranchNew`. Dispatcher maps adjusted. Per D15 no backwards-compat shim.

**D3-PR3-d: Risk-E enforced as runtime invariant.** SessionRouter's handle_info/call catch-alls explicitly drop data-plane messages and log WARN. Unit test verifies shapes like `{:inbound_msg, _}` never reach handlers.

**D3-PR3-e: Topology module deleted.** 1748 lines gone. SessionRegistry + SessionRouter + PeerFactory cover all topology responsibilities that ever existed.

**D3-PR3-f: peer_server.ex retained as generic frame.** 893 lines (was 939). `route` action removed. `emit` retained. Will trim further in PR-4b when adapter_runner consolidation lands.

---

## Tests added / known gaps

**Added (~15 new test files, 3 new integration)**:
- `cc_proxy_test.exs`, `cc_process_test.exs`, `session_router_test.exs` (+ boundary test)
- `capabilities_has_all_test.exs`, `grants_broadcast_test.exs`, `session_process_grants_test.exs`
- `session/new_test.exs` (agent-aware), `branch_new_test.exs` (renamed), `end_test.exs` (agent-aware)
- `pubsub_audit_test.exs` (allowlist guard)
- Integration: `cc_e2e_test.exs`, `n2_tmux_test.exs`, `new_chat_thread_signal_test.exs`
- `os_cleanup_test.exs` scaffold with `@tag :skip` (3 infra items pending)

**Removed (from P3-13/14)**:
- `test/esr/topology/*.exs` (5 files, ~580 lines)
- `test/esr/routing/slash_handler_test.exs`
- `test/esr/peer_server_invoke_command_test.exs`
- Various adapter_hub-only cases

**Total count**: 368 tests (down from 381 in PR-2 — net because P3-13/14 deleted more than P3-x added; counts are smaller modules after the Topology deletion).

**Known flakes** (documented in `docs/operations/known-flakes.md`):
- `cap_test.exs:149` — Grant.execute Watcher contract, global Grants GenServer race
- `tmux_process_test:162/:175` — **FIXED by erlexec migration** (pty option → no more flake)

---

## Tech debt carried to PR-4+

| Item | Where it surfaces | Resolution target |
|---|---|---|
| `SessionRouter.build_neighbors/1` is forward-only | FCP→CCProxy is wired, but CCProcess→TmuxProcess reverse link needs explicit wiring | PR-4a/b (when full peer chain exercised) or PR-5 |
| `mix test.e2e.os_cleanup` has 3 missing infra pieces | subprocess-esrd port/pid threading, WS helpers, per-instance tmux namespacing | PR-4+ when integration tests need ressurection |
| FCP drops non-slash messages | PR-3 didn't wire downstream because CC peers were new in this PR | PR-4a adds voice peers downstream; PR-4b consolidates adapter layer |
| Legacy MuonTrap references in `os_process.ex` moduledoc | Purely comments, no code | PR-5 doc cleanup |

---

## Next PR (PR-4a or PR-4b) expansion inputs

**PR-4a (voice-gateway split)** — when expanding, load:
- This snapshot (latest peer API shapes, including erlexec底座)
- erlexec skill: `.claude/skills/erlexec-elixir/` — CRITICAL (PyProcess and voice sidecars all use it)
- Spec §3.5 voice-e2e / cc-voice agents
- `py/voice_gateway/` current monolith code

**PR-4b (adapter_runner split)** — when expanding, load:
- This snapshot
- erlexec skill
- `py/src/esr/ipc/adapter_runner.py` current monolith
- `runtime/lib/esr/peer_server.ex` (to continue trimming)

---

## Links

- PR #14 (squash-merged): https://github.com/ezagent42/esr/pull/14
- Spec: `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md`
- Plan: `docs/superpowers/plans/2026-04-22-peer-session-refactor-implementation.md`
- Expanded PR-3: `docs/superpowers/progress/2026-04-23-pr3-expanded.md`
- Notes:
  - `docs/notes/erlexec-migration.md` (migration + MuonTrap appendix)
  - `docs/notes/feishu-ws-ownership-python.md`
  - `docs/notes/capability-name-format-mismatch.md` (marked RESOLVED)
  - `docs/notes/pubsub-audit-pr3.md`
- erlexec skill: `.claude/skills/erlexec-elixir/`

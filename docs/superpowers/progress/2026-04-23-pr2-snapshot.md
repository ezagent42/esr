# PR-2 Progress Snapshot

**Date**: 2026-04-23 (merged)
**Branch**: `feature/peer-session-refactor` (synced to `origin/main`)
**Squash-merge commit**: `fcef9e3` (on `main`)
**Status**: merged ✅

---

## New public API surfaces

### `Esr.AdminSession` (lib/esr/admin_session.ex)
- Supervisor, `:one_for_one`, `:permanent`
- Children: `AdminSessionProcess` + `DynamicSupervisor` (`ChildrenSupervisor`)
- `children_supervisor_name/1` — returns the children-sup name for dynamic additions
- Bootstrap-exception home: started directly by `Esr.Application`, NOT via `SessionRouter`/`PeerFactory`

### `Esr.AdminSessionProcess` (lib/esr/admin_session_process.ex)
- GenServer holding admin-level state
- `register_admin_peer(key_atom, pid)` — peers self-register at init
- `admin_peer(key_atom) :: {:ok, pid} | :error` — lookup by key
- `slash_handler_ref/0` — convenience for `admin_peer(:slash_handler)`
- `list_admin_peers/0` — enumerate all registered; added in P2-16 for Notify migration
- Monitors registered pids, cleans DOWN entries

### `Esr.PeerFactory.spawn_peer_bootstrap/4` (extended peer_factory.ex)
- Takes a literal `sup_name :: atom()` (not `session_id`) — the Risk F exception
- Emits `[:esr, :peer_factory, :spawn_bootstrap]` telemetry
- Bakes `session_id: "admin"` into init_args

### `Esr.Peers.FeishuAppAdapter` (lib/esr/peers/feishu_app_adapter.ex, 104 lines)
- `Peer.Stateful`; consumes `adapter:feishu/<app_id>` Phoenix-channel frames (does NOT own raw WS — Python-side `MsgBotClient` does; see `docs/notes/feishu-ws-ownership-python.md`)
- On `{:inbound_event, envelope}`: looks up target session via `SessionRegistry.lookup_by_chat_thread/2`, dispatches to FeishuChatProxy pid
- Self-registers in `AdminSessionProcess` as `:feishu_app_adapter_<app_id>` on init

### `Esr.Peers.FeishuChatProxy` (lib/esr/peers/feishu_chat_proxy.ex, 105 lines)
- `Peer.Stateful`; session inbound entry
- Slash detection: `slash?/1` checks first token for `/`
- `handle_upstream({:inbound, envelope}, state)`:
  - slash → sends to `AdminSessionProcess.slash_handler_ref/0` as `{:slash_cmd, env, reply_to: self()}`
  - non-slash → drops + logs (CC peers are PR-3; drop is the PR-2 "controlled failure" mode)

### `Esr.Peers.FeishuAppProxy` (lib/esr/peers/feishu_app_proxy.ex, 32 lines)
- `Peer.Proxy` with `@required_cap "cap.peer_proxy.forward_feishu"` — the first consumer of P2-4's macro extension
- Targets `admin::feishu_app_adapter_<app_id>`
- **Known issue**: the `cap.*` format doesn't match `Grants.matches?/2`'s parser; see `docs/notes/capability-name-format-mismatch.md` — to be resolved in PR-3 P3-8

### `Esr.Peers.SlashHandler` (lib/esr/peers/slash_handler.ex, 181 lines)
- `Peer.Stateful`; channel-agnostic slash parser
- Commands: `/new-session --agent <a> --dir <d>`, `/end-session <id>`, `/list-agents`, `/list-sessions`
- On parse: casts to `Esr.Admin.Dispatcher` as `session_agent_new` / `session_end` / etc.; waits for Dispatcher reply; formats human-readable response; sends back to `reply_to` pid

### `Esr.Peer.Proxy` macro extension (peer/proxy.ex)
- New: `@required_cap "cap.foo.bar"` attribute support
- Generates a wrapper over `forward/2` that checks `Esr.Capabilities.has?/2` on `proxy_ctx.principal_id` before forwarding
- Supports `Process.get(:esr_cap_test_override)` for test-time override
- **Preserves** P1-3's existing compile-time `handle_call`/`handle_cast` rejection

### `Esr.Session` (lib/esr/session.ex, 59 lines)
- Supervisor (`:one_for_all`, `:transient`); one per user session
- Children: `SessionProcess` + peers `DynamicSupervisor`
- `supervisor_name(session_id) :: atom()` — canonical name via `Registry`
- `start_link(session_id: id, agent_name: name, dir: path, ...)`

### `Esr.SessionProcess` (lib/esr/session_process.ex, ~75 lines)
- GenServer; holds `session_id`, `agent_name`, `dir`, `chat_thread_key`, `metadata`, `grants`
- `has?(pid, permission)` — P2-6a scaffold; pass-through to `Grants.has?/2`; becomes per-session in P3-3a

### `Esr.SessionsSupervisor` (lib/esr/sessions_supervisor.ex, 29 lines)
- `DynamicSupervisor`, `max_children: 128` (D17)
- `start_session(spec)` — wraps `start_child`; returns `{:error, :max_children}` at cap
- `stop_session(pid)`

### `Esr.Admin.Commands.Session.AgentNew` (lib/esr/admin/commands/session/agent_new.ex, 85 lines)
- NEW admin command; kind: `session_agent_new`
- Takes `agent`, `dir`, `principal_id`, `chat_id`, `thread_id`
- Spawns `{Esr.Session, spec}` under `SessionsSupervisor`
- Will be collapsed with `Session.New` in PR-3 P3-8 per spec D15

### `EsrWeb.AdapterChannel.forward_to_new_chain/2` (public)
- Topic-to-adapter resolution: `"adapter:feishu/" <> app_id → AdminSessionProcess.admin_peer(:feishu_app_adapter_<app_id>)`
- Sends `{:inbound_event, envelope}` to the resolved pid
- Returns `:ok | :error`

---

## Decisions locked in during PR-2

**D2-PR2-a: FeishuAppAdapter consumes Phoenix-channel frames, not raw WS.** Rationale: Feishu WebSocket stays in Python (`MsgBotClient`). Documented in `docs/notes/feishu-ws-ownership-python.md`. Not planned to flip.

**D2-PR2-b: `Session.AgentNew` is a NEW admin command in PR-2, not a rewrite of `Session.New`.** Rationale: legacy `Session.New` does branch-worktree spawning (dev-prod-isolation feature); the new agent-session concept is distinct. PR-3 P3-8 will consolidate per spec D15 (rename current to `Session.BranchNew`, make `Session.New` the agent-aware one).

**D2-PR2-c: P2-15 decommission scope is narrower than plan implied.** Only the `feishu_thread_proxy` dispatch branch in `peer_server.ex:terminate/2` was removed (6 lines). Broader CC code migration is PR-3 P3-16.

**D2-PR2-d: FeishuChatProxy drops non-slash messages in PR-2.** Controlled-failure stance: CC peers that would receive non-slash messages don't exist until PR-3 P3-1..P3-3. Drop+log is safer than a half-wired forward that crashes.

**D2-PR2-e: Capability name format in spec examples (`cap.session.create` etc.) does NOT match `Grants.matches?/2` parser.** Will be canonicalized to `prefix:name/perm` shape in PR-3 P3-8. See `docs/notes/capability-name-format-mismatch.md`. PR-2 tests sidestep via `["*"]` grants or test-mode override.

**D2-PR2-f: ExUnit test infrastructure**: 7 test files updated to use app-level processes (AdminSession, SessionsSupervisor, Session.Registry) rather than `start_supervised!`-ing them in tests. Documented why (application-level children can't be double-started).

**D2-PR2-g: `max_children: 128` applies only to SessionsSupervisor (user sessions). PeerPool's own pool limits are separate.** SessionsSupervisor enforces N-session cap; individual pools within sessions enforce their own caps.

---

## Tests added / removed

**Added** (in PR-2):
- `admin_session_test.exs` (4 tests)
- `peers/feishu_app_adapter_test.exs` (3 tests)
- `peers/feishu_chat_proxy_test.exs` (2 tests)
- `peer/proxy_compile_test.exs` (+2 new `@required_cap` tests; 5 total)
- `peers/feishu_app_proxy_test.exs` (3 tests)
- `peers/slash_handler_test.exs` (8 tests)
- `session_test.exs` (+3 tests on `SessionProcess.has?`)
- `sessions_supervisor_test.exs` (3 tests)
- `admin/commands/session/agent_new_test.exs` (~6 tests)
- `application_boot_test.exs` (new; verifies boot order + supervision tree shape)
- `adapter_channel_new_chain_test.exs` (3 tests)
- `integration/n2_sessions_test.exs` (1 test — cross-session isolation)
- `integration/new_session_smoke_test.exs` (3 tests — E2E slash flow)

**Removed** (legacy AdapterHub):
- `test/esr/adapter_hub/channel_test.exs` (163 lines, 14 tests)
- `test/esr/adapter_hub/registry_test.exs` (113 lines)
- `adapter_channel_feature_flag_test.exs` (P2-17 flag removed)

**Net delta**: +~30 tests, −16 tests; final count **362 tests + 5 integration = 367 covered**.

**Known flake additions surfaced during PR-2**:
- `session_test:57` — `:already_started` setup race on `Esr.Session.Registry`
- `feishu_app_adapter_test:60` — setup race
- `adapter_channel_new_chain_test:23` — similar setup race
- All are pre-existing patterns made visible by higher test concurrency against newly app-supervised registries. Logged in `docs/operations/known-flakes.md` (landed in PR #11) — will extend as PR-3 work intersects.

---

## Tech debt introduced (resolution targets)

| Item | Resolution |
|---|---|
| `FeishuAppProxy` uses `cap.*` name shape that `Grants.matches?/2` can't parse | PR-3 P3-8 canonicalizes spec-wide |
| `AgentNew` parallel to `Session.New` (branch-spawn) | PR-3 P3-8 consolidates |
| `validate_workspace_apps` no-op in `topology/instantiator.ex` | PR-3 P3-13 deletes Topology module entirely |
| `@tag :skip` in `workspace_validation_test.exs` | PR-3 restores via SessionRegistry |
| `FeishuChatProxy` drops non-slash messages | PR-3 P3-2..P3-3 wires CC peers downstream |

---

## Next PR (PR-3) expansion inputs

When expanding PR-3 outline into bite-sized steps, load:
- This snapshot (API shapes from PR-2)
- PR-1 snapshot (Peer behaviours + OSProcess底座)
- Spec §4.1 (CC peer cards), §5.3 (slash flow), §1.8 D15 D18 (session_new consolidation + capability check)
- `runtime/lib/esr/peer_server.ex` — legacy CC handling to migrate/delete
- `runtime/lib/esr/topology/*.ex` — to delete in PR-3 P3-13
- `runtime/lib/esr/peers/feishu_chat_proxy.ex` — to wire downstream to CCProxy

Key PR-3 open questions for the expansion session:
1. **How do CCProcess/CCProxy/TmuxProcess get started?** PeerFactory can spawn them, but who initiates? Option A: FeishuChatProxy on first non-slash message triggers a lazy spawn via SessionRouter; Option B: Session.AgentNew spawns the whole chain at session-create time. Spec §5.4 favors Option B.
2. **`Esr.SessionRouter` (control plane) creation**: from the outline P3-4. Define: what events it listens to, what it mutates, what it cannot mutate (SessionRegistry is owned by registry itself).
3. **Capability name canonicalization ordering**: do in P3-8 (before verify_caps wiring) or P3-1? If P3-1 needs cap checks for CCProxy, must come first.
4. **P3-3a Session-scoped projection**: scope of SessionProcess.grants population. Pull whole principal's grants? Subset? How does refresh work?

---

## Links

- PR #13 (squash-merged): https://github.com/ezagent42/esr/pull/13
- Spec: `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md`
- Plan: `docs/superpowers/plans/2026-04-22-peer-session-refactor-implementation.md`
- Expanded PR-2: `docs/superpowers/progress/2026-04-22-pr2-expanded.md` (20 tasks × bite-sized TDD steps)
- Notes:
  - `docs/notes/muontrap-mode3-constraint.md`
  - `docs/notes/feishu-ws-ownership-python.md`
  - `docs/notes/capability-name-format-mismatch.md`

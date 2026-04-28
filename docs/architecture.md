# ESR Architecture — post-refactor module tree

*Last updated 2026-04-28 (PR-F shipped). The canonical design lives in
`docs/design/ESR-Protocol-v0.3.md`; this document is the engineer's map
from that spec to code on disk. PRs are tracked under
`docs/superpowers/specs/<date>-<topic>.md`.*

## Elixir runtime (`runtime/lib/esr/`)

### Peer behaviours
- `esr/peer.ex` — `Esr.Peer` base behaviour. Every peer declares its `peer_kind` (`:proxy` or `:stateful`).
- `esr/peer/proxy.ex` — `Esr.Peer.Proxy` for request-forwarding peers. Compile-time callback-ban ensures no state.
- `esr/peer/stateful.ex` — `Esr.Peer.Stateful` for state-owning peers. Declares `handle_upstream/2`, `handle_downstream/2`; init belongs to the host GenServer / OSProcess.

### OS-process底座
- `esr/os_process.ex` — `Esr.OSProcess` macro layering `erlexec` (PTY + bidirectional stdio + BEAM-exit cleanup) over `Esr.Peer.Stateful`. See `docs/notes/erlexec-migration.md`.

### Per-chain peers (`runtime/lib/esr/peers/`)
- `feishu_app_adapter.ex` + `feishu_chat_proxy.ex` — Feishu inbound chain (PR-2).
- `cc_process.ex` + `cc_proxy.ex` + `tmux_process.ex` — CC chain (PR-3).
- `voice_asr.ex` + `voice_tts.ex` + `voice_e2e.ex` + `voice_asr_proxy.ex` + `voice_tts_proxy.ex` — Voice chain (PR-4a).

### Session supervision
- `esr/session.ex` + `esr/sessions_supervisor.ex` + `esr/session_process.ex` — per-user Session subtree (DynamicSupervisor + SessionProcess GenServer).
- `esr/admin_session.ex` + `esr/admin_session_process.ex` — permanent AdminSession (bootstraps pools + feishu app adapters).

### Control plane
- `esr/session_router.ex` — single serialized entry point for inbound-event dispatch. Risk E boundary.
- `esr/session_registry.ex` — YAML agent definitions + (chat_id, thread_id) → session mapping.
- `esr/peer_factory.ex` — spawns peer instances into the right session subtree.
- `esr/peer_pool.ex` + `esr/pools.ex` — pool manager for voice workers (shares via `pools.yaml` overrides).

### Multi-app routing (PR-A 2026-04-25)
- `esr/peers/feishu_app_adapter.ex` + `esr/peers/feishu_chat_proxy.ex` — every inbound now carries `args.app_id` (the originating Feishu instance_id from `adapters.yaml`); the field rides through the chain to the `<channel app_id=…>` attribute.
- Cross-app reply: `mcp__esr-channel__reply` requires explicit `app_id`. When `app_id != session.home_app`, FCP runs the cross-app gate: `Workspaces.Registry.workspace_for_chat(chat_id, app_id)` → `Capabilities.has?(principal, "workspace:<ws>/msg.send")` → `Registry.lookup(PeerRegistry, "feishu_app_adapter_<app_id>")`. Three deny shapes: `unknown_chat_in_app`, `forbidden`, `unknown_app` — all logged via `FCP cross-app deny type=…`.
- `reply_to_message_id` and `edit_message_id` are stripped on cross-app paths (source-app message_id space ≠ target-app's).
- E2E bypass for forbidden / non-member tests: `esr/admin/commands/cross_app_test.ex` admin command — drives FCP gate without CC (CC refuses `lateral_movement`-shaped instructions).
- See `docs/superpowers/specs/2026-04-25-pr-a-multi-app-design.md`.

### Single-lane authentication (Lane A drop, 2026-04-26)
- Pre-Lane-A removal had two enforcement lanes (Python adapter + Elixir runtime) which drifted. Now: `Esr.PeerServer` `handle_info({:inbound_event, _})` is the single gate; checks `workspace:<ws>/msg.send`; on deny, dispatches a deny-DM directive via the FAA peer.
- See `docs/notes/auth-lane-a-removal.md` (migration); `docs/notes/lane-a-rca.md` (why dual-lane existed).

### Topology + reachable_set (PR-C 2026-04-27)
- `esr/topology.ex` — yaml-driven actor topology. `initial_seed/3` produces a CC peer's bootstrap reachable_set (own chat + adapter + symmetric closure of yaml-declared neighbours). `neighbour_set/1` exposes the closure for any workspace.
- `esr/workspaces/registry.ex` — extended with `neighbors: [String.t()]` field per workspace + optional `chats[].name` for display-name resolution.
- `esr/workspaces/watcher.ex` — fs_watch on `workspaces.yaml`. Eager-add: broadcasts `{:topology_neighbour_added, ws, uri}` on `topology:<ws>` PubSub for active CC peers to merge into their reachable_set. Lazy-remove: cap gate is the authoritative revocation layer.
- `esr/peers/cc_process.ex` — owns per-actor `reachable_set: MapSet`. `learn_uris_from_event/2` performs BGP-style propagation (inbound `meta.source` + `meta.principal_id` → reachable_set). `build_channel_notification/2` emits `reachable` (JSON-string per spec §8 attribute-only constraint), `workspace`, and `user_id` on the `<channel>` tag.
- See `docs/superpowers/specs/2026-04-27-actor-topology-routing.md` and `docs/notes/actor-topology-routing.md`.

### cc_mcp `<channel>` attribute discipline (PR-D 2026-04-27)
- `notifications/claude/channel` only forwards flat attributes matching `[A-Za-z0-9_]+`. Nested children like `<reachable><actor/></reachable>` are silently dropped — PR-D pivoted to JSON-string attribute encoding for any list-shaped data (`reachable=` is the prototype).
- The whitelist of attributes is centralised in `adapters/cc_mcp/src/esr_cc_mcp/channel.py` `_handle_inbound`; `null` / empty values are filtered before injection so the LLM never sees half-populated tags.
- Spec note: `2026-04-27-actor-topology-routing.md` §8 documents the attribute-only constraint.

### Business-topology MCP tool (PR-F 2026-04-28)
- Adds `mcp__esr-channel__describe_topology` — parameter-less from the LLM's view; cc_mcp injects `workspace_name` from `ESR_WORKSPACE`.
- Runtime endpoint: `EsrWeb.CliChannel.dispatch("cli:workspaces/describe", …)` returns `{current_workspace, neighbor_workspaces}` filtered by an allowlist (`name`, `role`, `chats`, `neighbors_declared`, `metadata`). Operational fields (`cwd`, `env`, `start_cmd`) and secrets stay out.
- `Workspaces.Registry.Workspace` gains a `metadata: map()` free-form sub-tree — operators populate `purpose`, `pipeline_position`, `hand_off_to`, `output_format`, `not_my_job`, … without code changes. Schema is open.
- Tool is intended to be called when the LLM needs pipeline context (its role, downstream stages, expected output format) — not on every turn.
- See `docs/superpowers/specs/2026-04-28-business-topology-mcp-tool.md`, `docs/notes/actor-topology-routing.md` §"Authoring workspaces.yaml" → `metadata:`.

### Python subprocess supervision
- `esr/worker_supervisor.ex` — spawns / tracks `python -m <sidecar>` processes. `sidecar_module/1` dispatch table routes adapter names to their per-type sidecar module (`feishu_adapter_runner`, `cc_adapter_runner`, generic fallback).

### Capabilities
- `esr/capabilities.ex` + `esr/capabilities/grants.ex` — canonical `prefix:name/perm` permission model. Diff-based `{:grants_changed, principal_id}` PubSub drives session-scoped projection.
- Single enforcement lane (post 2026-04-26 Lane A drop): `Esr.PeerServer` `handle_info({:inbound_event, _}, _)` gates inbound on `workspace:<ws>/msg.send`, dispatches a deny-DM directive via the FAA peer on deny. See `docs/notes/auth-lane-a-removal.md` for the migration; `docs/notes/lane-a-rca.md` for why dual-lane existed and how to prevent it next time.

## Python code (`py/src/`)

### IPC plumbing — shared (PR-5)
- `_ipc_common/url.py` — port-file-aware URL resolution (both sides).
- `_ipc_common/reconnect.py` — exponential-backoff schedule.
- `_ipc_common/disconnect.py` — WS disconnect watcher.

### Adapter dispatch shared (PR-4b)
- `_adapter_common/runner_core.py` — `run` / `run_with_reconnect` / `run_with_client` + directive + event loops.
- `_adapter_common/main.py` — `build_main(allowed_adapters=..., prog=...)` factory used by every adapter sidecar.

### Per-type adapter sidecars (PR-4b)
- `feishu_adapter_runner/` — `ALLOWED_ADAPTERS = {"feishu"}`.
- `cc_adapter_runner/` — `ALLOWED_ADAPTERS = {"cc_tmux", "cc_mcp"}`.
- `generic_adapter_runner/` — catch-all migration fallback (prints DeprecationWarning).

### Handler worker
- `esr/ipc/handler_worker.py` — single Python handler-worker entry point. PR-5 consolidated its IPC helpers into `_ipc_common/`.

### Voice sidecars (PR-4a)
- `_voice_common/` — shared JSON-line engine.
- `voice_asr/__main__.py`, `voice_tts/__main__.py`, `voice_e2e/__main__.py`.

### Legacy / platform
- `esr/adapter.py` + `esr/adapters.py` — `@adapter` registry + loader.
- `esr/handler.py` — `@handler` registry.
- `esr/events.py` + `esr/ipc/envelope.py` + `esr/ipc/channel_client.py` + `esr/ipc/channel_pusher.py` — Phoenix-channel envelope schema + aiohttp-backed client.

## Scripts (`scripts/`)
- `spawn_scenario_workers.sh` — launches per-thread adapters + handlers for the e2e scenarios.
- `kill_scenario_workers.sh` — teardown counterpart.
- `esrd.sh` — install / start / stop / status / logs for the launchctl-supervised runtime.
- `spawn_worker.sh` — internal daemoniser invoked by `Esr.WorkerSupervisor`.
- `verify_entry_bodies.py` — LG-2 AST check; ensures declared entry points have non-trivial bodies.

## Test layout
- `runtime/test/esr/**` — ExUnit tests per module.
- `runtime/test/esr/integration/**` — tagged `:integration`, typically spawn real OS processes.
- `runtime/test/support/tmux_isolation.ex` — shared setup helper for per-socket tmux isolation (prevents leaked `esr_cc_*` sessions in the user's default socket).
- `py/tests/**` — pytest suites, including the PR-5 `ipc_common/`, the PR-4b `adapter_runners/`, and the pre-existing coverage under `esr/`.

## E2E coverage map

| Concern | Test |
|---|---|
| Single-user create / use / end | `tests/e2e/scenarios/01_single_user_create_and_end.sh` |
| Concurrent users + cap gating | `tests/e2e/scenarios/02_two_users_concurrent.sh` |
| Tmux pane operator attach | `tests/e2e/scenarios/03_tmux_attach_edit.sh` |
| Multi-app `app_id` propagation + cross-app deny | `tests/e2e/scenarios/04_multi_app_routing.sh` |
| Topology `<channel reachable=…>` + BGP learn | `tests/e2e/scenarios/05_topology_routing.sh` |
| Topology unit logic | `runtime/test/esr/topology_test.exs` |
| Topology integration (compose C1-C5) | `runtime/test/esr/topology_integration_test.exs` |
| `cli:workspaces/describe` (PR-F) | `runtime/test/esr_web/cli_channel_test.exs` |
| cc_mcp `describe_topology` injection | `adapters/cc_mcp/tests/test_describe_topology_invoke.py` |
| `<channel>` attribute filter (PR-D) | `adapters/cc_mcp/tests/test_notification_inject.py` |

> Adding a new feature with E2E impact: register the scenario in this
> table **and** in [`README.md`](../README.md) §"E2E test scenarios" so
> the index stays single-sourced.

## Cross-references
- Spec: `docs/design/ESR-Protocol-v0.3.md`, `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md`.
- PR-by-PR progress snapshots: `docs/superpowers/progress/2026-04-23-pr*-snapshot.md`.
- Developer notes: `docs/notes/README.md`.

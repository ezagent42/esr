# ESR Architecture — post-refactor module tree

*Generated 2026-04-23 after PR-1..PR-5 landed. The canonical design
lives in `docs/design/ESR-Protocol-v0.3.md`; this document is the
engineer's map from that spec to code on disk.*

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

### Topology + reachable_set (PR-C 2026-04-27)
- `esr/topology.ex` — yaml-driven actor topology. `initial_seed/3` produces a CC peer's bootstrap reachable_set (own chat + adapter + symmetric closure of yaml-declared neighbours). `neighbour_set/1` exposes the closure for any workspace.
- `esr/workspaces/registry.ex` — extended with `neighbors: [String.t()]` field per workspace + optional `chats[].name` for display-name resolution.
- `esr/workspaces/watcher.ex` — fs_watch on `workspaces.yaml`. Eager-add: broadcasts `{:topology_neighbour_added, ws, uri}` on `topology:<ws>` PubSub for active CC peers to merge into their reachable_set. Lazy-remove: cap gate is the authoritative revocation layer.
- `esr/peers/cc_process.ex` — owns per-actor `reachable_set: MapSet`. `learn_uris_from_event/2` performs BGP-style propagation (inbound `meta.source` + `meta.principal_id` → reachable_set). `build_channel_notification/2` emits `reachable` (JSON-string per spec §8 attribute-only constraint), `workspace`, and `user_id` on the `<channel>` tag.
- See `docs/superpowers/specs/2026-04-27-actor-topology-routing.md` and `docs/notes/actor-topology-routing.md`.

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

## Cross-references
- Spec: `docs/design/ESR-Protocol-v0.3.md`, `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md`.
- PR-by-PR progress snapshots: `docs/superpowers/progress/2026-04-23-pr*-snapshot.md`.
- Developer notes: `docs/notes/README.md`.

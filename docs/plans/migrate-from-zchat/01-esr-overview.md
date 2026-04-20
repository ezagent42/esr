# ESR v0.2-channel — current state

This document captures ESR's routing-relevant surface as of branch [`v0.2-channel`](https://github.com/ezagent42/esr/tree/v0.2-channel). It's the *what we have today* baseline that the migration will modify.

## 1. Four-layer architecture

```
  Layer 4   Command       Python EDSL → YAML topology artifact
              │
              ▼
  Layer 1   Runtime       Elixir / OTP — PeerServer per actor
              ▲                          + Phoenix.PubSub
              │
              │ handler_call / handler_reply         ▲
              │                                       │ directive / event
  Layer 2   Handler                          Layer 3 Adapter
            (Python, pure)                            (Python, I/O)
            (state, event) → (state', actions)        factory → impure I/O
```

See [`docs/superpowers/specs/2026-04-18-esr-extraction-design.md`](../../superpowers/specs/2026-04-18-esr-extraction-design.md) §2 for the full architecture and the rationale for each layer boundary.

## 2. Key Elixir source files

| File | Role |
|---|---|
| [`runtime/lib/esr/peer_server.ex`](https://github.com/ezagent42/esr/blob/v0.2-channel/runtime/lib/esr/peer_server.ex) | Per-actor mailbox (GenServer); applies handler-returned actions |
| [`runtime/lib/esr/handler_router.ex`](https://github.com/ezagent42/esr/blob/v0.2-channel/runtime/lib/esr/handler_router.ex) | Phoenix.PubSub envelope dispatch to Python workers; awaits reply |
| [`runtime/lib/esr/topology/registry.ex`](https://github.com/ezagent42/esr/blob/v0.2-channel/runtime/lib/esr/topology/registry.ex) | ETS registry of `(name, params) → peer_ids`; idempotent |
| [`runtime/lib/esr/topology/instantiator.ex`](https://github.com/ezagent42/esr/blob/v0.2-channel/runtime/lib/esr/topology/instantiator.ex) | Topology graph reconciliation; spawns peer chains |
| [`runtime/lib/esr/workspaces/registry.ex`](https://github.com/ezagent42/esr/blob/v0.2-channel/runtime/lib/esr/workspaces/registry.ex) | `workspaces.yaml` ETS cache; GenServer + named ETS pattern |
| [`runtime/lib/esr/session_registry.ex`](https://github.com/ezagent42/esr/blob/v0.2-channel/runtime/lib/esr/session_registry.ex) | v0.2 `session_id → {peer_pid, ws_pid, chat_ids, workspace}` |
| [`runtime/lib/esr_web/channel_channel.ex`](https://github.com/ezagent42/esr/blob/v0.2-channel/runtime/lib/esr_web/channel_channel.ex) | v0.2 `cli:channel/<session_id>` Phoenix Channel for the esr-channel MCP bridge |
| [`runtime/lib/esr/adapter_hub/registry.ex`](https://github.com/ezagent42/esr/blob/v0.2-channel/runtime/lib/esr/adapter_hub/registry.ex) | Adapter instance discovery |

## 3. Key Python source files

| File | Role |
|---|---|
| [`handlers/feishu_app/src/esr_handler_feishu_app/state.py`](https://github.com/ezagent42/esr/blob/v0.2-channel/handlers/feishu_app/src/esr_handler_feishu_app/state.py) | `FeishuAppState` — `bound_threads`, `active_thread_by_chat`, `last_chat_id` |
| [`handlers/feishu_app/src/esr_handler_feishu_app/on_msg.py`](https://github.com/ezagent42/esr/blob/v0.2-channel/handlers/feishu_app/src/esr_handler_feishu_app/on_msg.py) | App-proxy handler: `/new-session`, `/new-thread` (compat), `@<tag>` routing |
| [`handlers/feishu_thread/src/esr_handler_feishu_thread/state.py`](https://github.com/ezagent42/esr/blob/v0.2-channel/handlers/feishu_thread/src/esr_handler_feishu_thread/state.py) | `FeishuThreadState` — dedup (1000 cap), chat_id |
| [`handlers/feishu_thread/src/esr_handler_feishu_thread/on_msg.py`](https://github.com/ezagent42/esr/blob/v0.2-channel/handlers/feishu_thread/src/esr_handler_feishu_thread/on_msg.py) | Thread-proxy handler: `feishu_msg_received`, `cc_output` |
| [`adapters/feishu/src/esr_feishu/adapter.py`](https://github.com/ezagent42/esr/blob/v0.2-channel/adapters/feishu/src/esr_feishu/adapter.py) | Feishu adapter — lark_oapi WS + REST; rate-limit + 30 s retry budget |

## 4. What v0.2-channel is currently building

Per [v0.2 design](../../superpowers/specs/2026-04-20-esr-v0.2-channel-design.md):

- `esr-channel` MCP bridge — Python stdio server that proxies CC sessions to esrd over WS
- Multi-app workspaces — `workspaces.yaml` lists each chat with its owning `app_id`
- Primary path swap from `cc_tmux.send_keys` to MCP notification
- Adapter+topology auto-restore on esrd start

That work is in progress on the active branch and is *out of scope* for this migration document — the migration here is the *next* iteration after v0.2 lands.

## 5. What's ESR-only that the migration preserves

The migration to absorb zchat capabilities does **not** lose any of these ESR properties:

- **Actor supervision (OTP)** — per-actor restart policies, hierarchical supervision trees (continues to live in Elixir; invisible to Python authors after migration)
- **Topology compilation (Layer 4)** — declarative multi-step orchestration with EDSL → YAML pipeline (e.g., `feishu-thread-session`)
- **Adapter purity boundary** — `@adapter(allowed_io=...)` declaration enables CI-enforced I/O surface
- **Phoenix Channel transport** — `cli:channel/<session_id>` for the esr-channel MCP bridge (v0.2 deliverable)
- **CC session lifecycle** — `feishu-thread-session` topology, `cli:workspace/register` push model
- **GenServer + ETS for shared state** — already idiomatic OTP usage in `Esr.Workspaces.Registry`, `Esr.Topology.Registry`; the new `projection_table` primitive in [`04-target-design.md`](./04-target-design.md) is a thin Python-facing wrapper over this same pattern

# Comparison: routing-functionality overlap

This document is the head-to-head comparison of zchat refactor/v4 and ESR v0.2-channel on routing concerns. It assumes you've read [`01-esr-overview.md`](./01-esr-overview.md) and [`02-zchat-overview.md`](./02-zchat-overview.md), or already know both codebases.

## 1. Overlap matrix

| Routing concern | ESR (v0.2-channel) | zchat (refactor/v4) | Overlap kind |
|---|---|---|---|
| Multi-app / multi-bot configuration | `workspaces.yaml` chats per app + per-app `feishu-app-session` topology | `routing.toml [bots]/[channels].bot` (V6 schema) | **Same problem, different schema** |
| `external_chat_id` ↔ logical channel binding | `workspaces.chats[]` + handler `chat_id` field; v0.2 `SessionRegistry.chat_ids` | `[channels.X].external_chat_id` | **Direct overlap** |
| Per-chat session/thread mapping | `feishu_app_proxy.active_thread_by_chat` (multiple threads per chat) | `[channels.X].entry_agent` (single entry per channel) | **Partial overlap** — ESR is finer-grained |
| Dynamic registration | `cli:workspace/register` push (CLI → runtime) | `RoutingWatcher` mtime poll + IRC JOIN/PART diff | **Same goal, different mechanism** |
| `/cmd` dispatch | Pattern-match in `feishu_app/on_msg` (hardcoded prefixes) | `PluginRegistry.handles_commands()` (declarative) | **Overlap, different extension model** |
| Inbound message dedup | `FeishuThreadState.dedup` (handler state, 1000 cap, persisted via ETS checkpoint) | `FeishuBridge._processed_msg_ids` (bridge process, 10000 cap, in-memory) | **Overlap, different layer** |
| Message editing | v0.2 `reply(edit_message_id?)` MCP tool | `__edit:` IRC prefix + `reply(edit_of=)` | **Overlap** |
| Operator copilot/takeover mode | **Not present** | `mode` plugin + `__zchat_sys:` events | **zchat-only** |
| Operator side-channel messages | **Not present** | `__side:` IRC prefix | **zchat-only** |
| SLA / audit / CSAT / activation | **Not present** | `sla / audit / csat / activation` plugins | **zchat-only** |
| Inter-agent broadcast | Actor PubSub (Phoenix.PubSub) | IRC `#channel` PRIVMSG (everyone in channel sees) | **Different paradigm — incompatible** |
| Persistence | ETS + periodic checkpoint (OTP) | `routing.toml` + `customer_chats.json` flat files | Different layer |

## 2. Reading the matrix

The matrix surfaces three distinct categories:

### Category A — same problem, different schema (5 rows)

Multi-bot config, `external_chat_id` binding, dynamic registration, `/cmd` dispatch, dedup. Both codebases solve these; the migration consolidates on a single schema and mechanism (zchat's `routing.toml` + ESR's CLI push). Per-chat session mapping is partial-overlap and ESR keeps its finer-grained model.

### Category B — zchat-only that we want (3 rows)

Mode (copilot/takeover), SLA / audit / CSAT / activation plugins, message editing. These are net-additive features for ESR. The migration ports the *behavior* via the new Python primitives; it does **not** copy zchat's plugin class verbatim.

### Category C — paradigm-incompatible (1 row)

Inter-agent broadcast: zchat uses IRC `#channel` PRIVMSG (everyone in channel sees); ESR uses Phoenix.PubSub (subscribers register explicitly). Not bridgeable. The migration keeps Phoenix.PubSub and does *not* introduce IRC. See [`02-zchat-overview.md §6`](./02-zchat-overview.md#6-what-we-dont-want-from-zchat).

## 3. Capabilities that are zchat-only AND we don't want

Already covered in [`02-zchat-overview.md §6`](./02-zchat-overview.md#6-what-we-dont-want-from-zchat). Summary:

- IRC-as-fabric (use Phoenix.PubSub instead)
- WeeChat / ergo runtime dependencies (drop)
- Plugin class with imperative `self._modes` state (use `projection_table` instead)

## 4. What guides the migration target

The matrix shapes the [target design](./04-target-design.md) in three concrete ways:

1. **Category A consolidation** drives the new `projection_table` primitive — the OTP-native equivalent of zchat's plugin-internal state dict.
2. **Category B porting** drives the new `transform` + `react` primitives — the ESR-native equivalent of zchat's `handles_commands()` + `on_command()` plugin protocol.
3. **Category C avoidance** confirms that ESR keeps its actor-runtime fabric and absorbs zchat capabilities at the Python-API level only, not at the runtime fabric level.

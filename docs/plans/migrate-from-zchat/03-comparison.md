# Comparison: full feature inventory + ESR-native mapping

This document is the head-to-head comparison of the **entire zchat umbrella repo** and ESR v0.2-channel. The migration target is full absorption of zchat capabilities into ESR; this matrix surfaces *every* zchat feature with its proposed ESR equivalent.

Read [`01-esr-overview.md`](./01-esr-overview.md) and [`02-zchat-overview.md`](./02-zchat-overview.md) first if you don't already know the codebases.

## 1. Full feature inventory (18 rows)

| # | zchat feature | zchat impl | ESR-native equivalent |
|---|---|---|---|
| 1 | **Inter-agent communication** | IRC channels via ergo + irc_encoding prefixes | **Phoenix.PubSub + projection_table** for channel-scoped state. Channel concept maps to a PubSub topic *or* a projection key; no IRC fabric. |
| 2 | **Agent lifecycle** (create/stop/list/restart/send) | `agent_manager.py` (370 LOC) + `~/.local/state/zchat/agents.json` + zellij tabs | **`esr adapter <name> <verb>` per-adapter CLI** + Topology + SessionRegistry. `esr adapter cc_zellij {list,create,stop,focus}` etc. Each adapter declares its own verbs. |
| 3 | **Project concept** | `~/.zchat/projects/<name>/` directory + per-project config + agent grouping | **ESR `workspace` (unchanged)** — per [decision ①C], workspace stays as the unit; no project layer added. Project becomes an aggregation view in `routing.toml` `[projects.<name>]` if needed (deferred). |
| 4 | **Authentication** | `auth.py` 272 LOC: OIDC device code flow + token cache + Logto discovery | **CBAC (already in ESR) + Feishu identity** as the principal. *No auth phase in v0.3* — deferred per user direction; the OIDC implementation is informative but not absorbed. |
| 5 | **Multiplexer (zellij CLI integration)** | `zellij.py` (180 LOC) + agent_manager integration | **`adapters/cc_zellij/`** — borrows `zellij.py` wrapper code; mirrors `cc_tmux` directives (`new_session / send_keys / kill_session / dump_pane`). |
| 6 | **In-zellij UI** | Rust crates `zchat-palette` + `zchat-status` (zellij-tile plugins) | **CLI-only for v0.3** per [decision ②C]; `esr adapter cc_zellij list` covers status; in-pane plugin deferred (web UI candidate for v0.4+). |
| 7 | **WeeChat IRC plugin** | `weechat-zchat-plugin/zchat.py` (284 LOC): /agent commands + presence + sys rendering | **Not directly absorbed** — IRC retired. Functionality split: command verbs → `esr adapter <n> ...` CLI; presence → P3 CLI; sys rendering → ESR Event types. |
| 8 | **Routing schema** | `routing.toml [bots]/[channels]` (V6) | **`routing.toml` extended with ESR fields** (workspace ref, per-channel overrides) — replaces `workspaces.yaml` + `adapters.yaml`. P1. |
| 9 | **Per-chat session/thread mapping** | `[channels.X].entry_agent` (single entry) | **`active_thread_by_chat` projection table** — multiple threads per chat (already finer-grained in ESR v0.2). |
| 10 | **Dynamic registration** | `RoutingWatcher` mtime poll + IRC JOIN/PART diff | **`esr routing reload` push CLI** + projection diff → topology start/stop. P1. |
| 11 | **`/cmd` dispatch** | `PluginRegistry.handles_commands()` (declarative) | **`react(pattern={"meta.slash_cmd": "..."}, handler=...)`** — declarative pattern in P4. |
| 12 | **Channel mode (copilot/takeover)** | `mode` plugin (50 LOC) with `self._modes` dict | **`react` + `projection_table("channel_modes")`** in P5. See [`04-target-design.md`](./04-target-design.md) §6 for the worked example. |
| 13 | **SLA / audit / CSAT / activation / resolve** | 5 plugins, ~600 LOC total | **`react` + topology spawning** in P5. SLA's timer = topology with `Process.send_after`; audit = new `adapters/audit` writing to SQLite; csat = new `csat-survey` topology. |
| 14 | **Inbound message dedup** | `FeishuBridge._processed_msg_ids` (10000 cap, in-memory) | **`projection_table("dedup_seen", default=frozenset)`** — already finer in ESR (per-thread, persisted via ETS checkpoint). |
| 15 | **Message editing** | `__edit:<uuid>:<text>` IRC prefix + `reply(edit_of=)` | **`Emit("feishu", "edit_message", {message_id, content})`** — handler-level action; adapter knows Feishu API. *Not* a protocol kind. |
| 16 | **Operator side messages** (operator-only visible) | `__side:<text>` IRC prefix | **adapter directive with `visibility` parameter** OR separate sink `Emit("feishu_side", ...)`. P5. *Not* a protocol kind. |
| 17 | **Naming convention** | `scoped_name(name, username)` returns `username-agentname` (`AGENT_SEPARATOR = "-"`) | **Direct adoption** — ESR adapts agent identity to scoped form for human readability. P3. |
| 18 | **Doctor / env check** | `zchat doctor` (179 LOC) — checks Python/ergo/weechat/zellij | **`esr doctor`** — checks Erlang/Elixir/Python/zellij/feishu credentials. P3. |
| 19 | **Project templates / runner** | `runner.py` + `template_loader.py` template substitution | **Extend ESR `workspace.start_cmd`** with template vars. P1. |
| 20 | **Persistence** | `routing.toml` + `customer_chats.json` flat files | **ETS + periodic checkpoint (OTP)** — already in ESR. |
| 21 | **Self-update + Homebrew** | `update.py` (release/main channels) + Homebrew tap | **Deferred to v0.4+** per [decision ③b]. |
| 22 | **`ws_messages.py` bridge↔server WS contract** | 6 envelope types | **Not absorbed** — ESR's adapter does I/O directly; the bridge↔server WS hop doesn't exist in ESR's architecture. |

## 2. Reading the matrix

22 rows in 4 categories:

### Category A — fully absorbed (12 rows: #2, #5, #8, #9, #10, #11, #12, #13, #14, #17, #18, #19)

zchat capability is reproduced in ESR with an OTP-native mechanism. Mapping is concrete and falls into specific migration phases.

### Category B — semantics absorbed, mechanism rejected (3 rows: #1, #15, #16)

The *behavior* is reproduced (mode-gated routing, message editing, operator-only visibility) but the IRC-prefix encoding mechanism is dropped. ESR uses native Phoenix.PubSub + handler actions + adapter directives.

### Category C — deferred or not relevant (4 rows: #4, #6, #21, #22)

- Auth → CBAC + Feishu identity (no migration needed)
- In-zellij UI → CLI-first for v0.3
- Self-update + distribution → v0.4+
- bridge↔server protocol → architecturally absent in ESR

### Category D — replaced (1 row: #3)

- Project → workspace (no rename) + optional aggregation view in routing.toml

### Category E — drop entirely (2 rows: #7, ergo-inside)

- WeeChat plugin → CLI + future web UI cover its surface; IRC retired
- ergo IRC server → not needed (no IRC)

## 3. What guides the migration target

The matrix shapes the [target design](./04-target-design.md) and the [migration plan](./05-migration-plan.md):

1. **Category A consolidation** drives the `projection_table` primitive (#8, #9, #10, #11, #12, #14) and per-adapter CLI surface (#2, #18) — the OTP-native equivalents of zchat's plugin-internal state and unified `zchat agent` CLI.
2. **Category B porting** drives the `transform` + `react` primitives — the ESR-native equivalent of zchat's `handles_commands()` + `on_command()` plugin protocol, plus dropping the IRC prefix layer.
3. **Category C/D/E avoidance** confirms what ESR does *not* take: auth, IRC fabric, distribution mechanism. ESR keeps its actor-runtime fabric, CBAC security model, and current distribution (Mix release / uv / etc.).

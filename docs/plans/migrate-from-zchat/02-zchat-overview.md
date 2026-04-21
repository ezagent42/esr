# zchat — full umbrella repo overview

This document orients ESR-side readers to **the entire `ezagent42/zchat` umbrella repo**, not just the IRC channel server. The migration target is full absorption of zchat capabilities into ESR.

## 1. Umbrella structure

[`ezagent42/zchat`](https://github.com/ezagent42/zchat) is the umbrella repo that pulls together 6 submodules + 2 local packages:

```
zchat/                              # umbrella repo
├── zchat/                          # top-level CLI Python package (~4000 LOC)
│   └── cli/                        # 22 files: agent / project / irc / auth / zellij / runner / ...
├── zchat-channel-server/           # submodule → ezagent42/claude-zchat-channel
│   └── src/                        # IRC ↔ WS router + plugins (mode/sla/audit/csat/...)
├── zchat-protocol/                 # submodule → ezagent42/zchat-protocol  (refactor/v4 branch)
│   └── zchat_protocol/             # irc_encoding + ws_messages + naming
├── weechat-zchat-plugin/           # submodule → ezagent42/weechat-zchat-plugin
│   └── zchat.py                    # WeeChat /agent commands + sys rendering (284 LOC)
├── zchat-hub-plugin/               # local Rust workspace
│   ├── zchat-palette/              # zellij in-pane command palette
│   └── zchat-status/               # zellij status bar
├── ergo-inside/                    # submodule → ezagent42/ergo-inside (IRC server config)
├── homebrew-zchat/                 # submodule → ezagent42/homebrew-zchat (Homebrew tap)
└── ezagent42-marketplace/          # submodule (Claude Code plugin marketplace, unrelated)
```

The user-facing pitch (per umbrella `README.md`): *本地多 Agent 协作系统，基于 WeeChat + Claude Code，通过 IRC 协议连接*. Install via `curl ... | bash` or Homebrew; one-stop CLI `zchat agent / project / irc / auth / doctor / update`.

## 2. zchat-protocol (refactor/v4)

The shared protocol package — the *one source of truth* for message kinds across channel-server, weechat plugin, and (future) ESR.

| File | LOC | Role |
|---|---:|---|
| [`zchat_protocol/irc_encoding.py`](https://github.com/ezagent42/zchat-protocol/blob/refactor/v4/zchat_protocol/irc_encoding.py) | 90 | **5 message kinds** encoded as IRC PRIVMSG content prefixes: `__msg:<uuid>:<text>`, `__edit:<uuid>:<text>`, `__side:<text>`, `__zchat_sys:<json>`, plain text. `encode_*` + `parse()` |
| [`zchat_protocol/ws_messages.py`](https://github.com/ezagent42/zchat-protocol/blob/refactor/v4/zchat_protocol/ws_messages.py) | 82 | bridge ↔ channel-server WS contract: 6 envelope types (`register / registered / message / event / command / ack`); `build_*` + `parse()` |
| [`zchat_protocol/naming.py`](https://github.com/ezagent42/zchat-protocol/blob/refactor/v4/zchat_protocol/naming.py) | 11 | Agent naming: `scoped_name(name, username)` returns `username-agentname`; `AGENT_SEPARATOR = "-"` |

**Important**: kind in `irc_encoding.py` is a *protocol* artifact, not a *business semantic* — IRC PRIVMSG can only carry text, so kind has to be encoded as a prefix. `edit` and `side` are *business semantics* (message editing; operator-only visibility) that happen to be carried via this protocol mechanism. ESR doesn't need a corresponding "kind" primitive — those semantics map to handler actions and adapter directives. See [`05-migration-plan.md`](./05-migration-plan.md) P5.

## 3. Top-level zchat CLI Python package

The umbrella repo contains a substantial CLI package (~4000 LOC) that is **not** a submodule — this is the operational surface.

| File | LOC | Role |
|---|---:|---|
| `zchat/cli/app.py` | 1317 | Main CLI dispatcher (`zchat agent / project / irc / auth / doctor / update / migrate / config`) |
| `zchat/cli/agent_manager.py` | 370 | **Agent lifecycle**: create workspace, spawn zellij tab, track state in `~/.local/state/zchat/agents.json`, restart |
| `zchat/cli/irc_manager.py` | 325 | ergo IRC daemon + WeeChat zellij-pane management |
| `zchat/cli/auth.py` | 272 | **OIDC device code flow** + token cache/refresh + Logto discovery + QR display |
| `zchat/cli/runner.py` | 233 | Runner template resolution + env file rendering |
| `zchat/cli/zellij.py` | 180 | zellij CLI helpers: `ensure_session / new_tab / write_chars / list_panes` |
| `zchat/cli/update.py` | 176 | Self-update (release / main two channels) |
| `zchat/cli/doctor.py` | 179 | Environment check (Python / ergo / weechat / zellij installed) |
| `zchat/cli/project.py` | 159 | `project create / use / switch` (workspace dir per project) |
| `zchat/cli/paths.py` | 159 | `~/.zchat/` + `~/.local/state/zchat/` path helpers |
| `zchat/cli/template_loader.py` | 111 | Per-template TOML loading |
| `zchat/cli/migrate.py` | 114 | Schema version migrations |
| `zchat/cli/ergo_auth_script.py` | 108 | ergo IRC auth integration |
| `zchat/cli/config_cmd.py` | 106 | `zchat config get/set` |
| `zchat/cli/layout.py` | 97 | zellij layout templates |
| `zchat/cli/defaults.py` | 34 | Default constants |

## 4. claude-zchat-channel (the IRC ↔ WS broker — submodule)

Active branch: [`refactor/v4`](https://github.com/ezagent42/claude-zchat-channel/tree/refactor/v4).

```
       Feishu / Lark
            │
            ▼  (per-bot WSS for inbound + REST for outbound)
       feishu_bridge ─────WS─────►  channel_server  ◄────IRC────►  ergo (IRC server)
                                          │                                 │
                                          ▼                                 ▼
                                    PluginRegistry                     agent_mcp.py
                                     (mode / sla / audit                (per-agent CC
                                      / csat / activation /              in zellij pane)
                                      resolve)
```

| File | Role | LOC |
|---|---|---:|
| [`src/channel_server/router.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/channel_server/router.py) | WS↔IRC bidirectional translation; `/cmd` dispatch; mode-dependent `@<entry_agent>` prefix | 194 |
| [`src/channel_server/routing.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/channel_server/routing.py) | `RoutingTable` + `Bot` + `ChannelRoute` dataclasses; V6 schema parser | 115 |
| [`src/channel_server/routing_watcher.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/channel_server/routing_watcher.py) | mtime poll → reload + IRC JOIN/PART diff | 103 |
| [`src/channel_server/plugin.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/channel_server/plugin.py) | Plugin protocol + `PluginRegistry` + command-conflict detection | 106 |
| [`src/feishu_bridge/bridge.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/feishu_bridge/bridge.py) | Per-bot Feishu listener + dedup + outbound routing | 676 |
| [`src/feishu_bridge/routing_reader.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/feishu_bridge/routing_reader.py) | bot-scoped `routing.toml` filter; bridge stays decoupled | 96 |
| [`src/plugins/mode/plugin.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/plugins/mode/plugin.py) | copilot/takeover state machine; emits `mode_changed` events | 50 |
| [`src/plugins/sla/plugin.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/plugins/sla/plugin.py) | takeover-timeout + help-timeout asyncio timers | ~200 |

### V6 `routing.toml` schema

```toml
[bots."customer"]
app_id                  = "cli_..."
credential_file         = "credentials/customer.json"
default_agent_template  = "fast-agent"
lazy_create_enabled     = true

[channels."conv-001"]
bot              = "customer"          # references [bots] name
external_chat_id = "oc_客户群A"
entry_agent      = "alice-fast0"
[channels."conv-001".agents]
fast = "alice-fast0"
deep = "alice-deep0"
```

Multi-bot routing: a single `channel_server` loads all `[channels]`; each bridge process filters channels by `bot=` to know which subset it owns. Reference: [`routing.example.toml`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/routing.example.toml).

### Plugin model in 30 lines

```python
class ModePlugin(BasePlugin):
    name = "mode"
    def __init__(self, emit_event):
        self._modes: dict[str, str] = {}
        self._emit_event = emit_event
    def handles_commands(self): return ["hijack", "release", "copilot"]
    async def on_command(self, cmd, msg):
        channel = msg.get("channel", "")
        old = self._modes.get(channel, "copilot")
        new = "takeover" if cmd == "hijack" else "copilot"
        self._modes[channel] = new
        await self._emit_event("mode_changed", channel, {"from": old, "to": new})
    def query(self, key, args):
        if key == "get": return self._modes.get(args.get("channel", ""), "copilot")
```

Declare commands, hold state in `self`, expose `query()`. Other plugins (sla, audit, csat) follow the same template.

## 5. weechat-zchat-plugin (submodule)

[`ezagent42/weechat-zchat-plugin`](https://github.com/ezagent42/weechat-zchat-plugin) — a single 284-LOC WeeChat Python script:

- `/agent` command (create / stop / list / restart / send via shelling out to `zchat` CLI)
- @mention highlighting for agent nicks
- Agent presence tracking (JOIN / PART / QUIT in IRC)
- `__zchat_sys:` rendering (machine-to-machine sys → human-readable line)
- Status bar item

**Notable**: the protocol decoder is **independently reimplemented** here (no imports from the `zchat` Python package), since WeeChat plugins run in WeeChat's own embedded Python. This is a hint about how distribution-coupled the protocol concepts are.

## 6. zchat-hub-plugin (local Rust workspace, **not a submodule**)

A Rust workspace inside the umbrella repo, providing **zellij in-pane UI**:

| Crate | Role |
|---|---|
| `zchat-palette` | zellij command palette (built on `zellij-tile = "0.44"`) |
| `zchat-status` | zellij status bar (per-agent live status) |

Both are loaded as zellij plugins (`.wasm`) into running zellij sessions. They render UI elements that read zchat agent state.

This is a dimension I had completely missed in v1 of the migration plan.

## 7. ergo-inside, homebrew-zchat (operational submodules)

- [`ergo-inside`](https://github.com/ezagent42/ergo-inside) — local IRC server config (ergo daemon's `.yaml` config + accompanying scripts)
- [`homebrew-zchat`](https://github.com/ezagent42/homebrew-zchat) — Homebrew tap for `brew install ezagent42/zchat/zchat` distribution

Both are **operationally relevant** (install + IRC daemon) but not "business code". Migration plan handles distribution as deferred (see decision ③ in [`README.md`](./README.md)).

## 8. What we want from zchat (updated for full merger)

Now that the migration target is **complete absorption**, the want-list expands beyond the v1 plan:

- **Routing schema** (`routing.toml [bots]/[channels]`) — ops-friendly single-file definition
- **mode / sla / audit / csat / activation / resolve plugins** — workflow primitives
- **zellij multiplexer launch model** + `zellij.py` CLI wrappers
- **OIDC auth flow** (`auth.py` device code + token cache) — *but see decision update*: ESR replaces this with CBAC + Feishu identity, **not** OIDC. The auth.py code is informative but not directly absorbed.
- **Agent lifecycle CLI** (`zchat agent ...`) — but adapted to ESR's per-adapter CLI pattern (`esr adapter cc_zellij list`, etc.)
- **`scoped_name` naming convention** — agent identifiers become `username-agentname` for human readability
- **Project/workspace concept** — covered by ESR's existing `workspace` (no rename per decision ①)
- **`doctor` env check** — `esr doctor` mirrors `zchat doctor`'s shape
- **Runner template / env file** — extends ESR workspace.start_cmd with template variable substitution

## 9. What we don't want from zchat

- **IRC-as-fabric** (ergo, irc_encoding's IRC PRIVMSG dependency, WeeChat plugin) — ESR uses Phoenix.PubSub for inter-actor; user-facing IM uses Feishu/web adapter. WeeChat plugin's *user-facing functionality* (CLI verbs + presence) is provided instead by `esr adapter <n> ...` commands.
- **Plugin imperative state model** (`class ModePlugin: self._modes = {}`) — ESR uses `projection_table` + `react` instead. Same behavior, OTP-native mechanism.
- **OIDC auth** (deferred per decision; CBAC + Feishu identity is the v0.3 security model)
- **Self-update + Homebrew distribution** (deferred per decision ③ to v0.4+)
- **zellij hub plugin port** (deferred per decision ② — CLI-first for v0.3, in-zellij UI evaluated later)
- **`ws_messages.py` bridge↔server protocol** — ESR's adapter does I/O directly without a separate bridge process; the WS envelope is a zchat-specific intermediate

# zchat refactor/v4 — what we're absorbing from

This document orients ESR-side readers to zchat's current architecture and identifies which capabilities the migration absorbs (and which it deliberately doesn't).

[`claude-zchat-channel`](https://github.com/ezagent42/claude-zchat-channel) is a Python channel router that bridges IRC ↔ WebSocket for multi-agent customer-service-style workflows. Active branch: [`refactor/v4`](https://github.com/ezagent42/claude-zchat-channel/tree/refactor/v4). The most recent commit on the branch (at the time of this writing) is `d6fae20 refactor(bridge): V6 — 从 routing.toml [bots] 派生配置`.

## 1. Architecture

```
       Feishu / Lark
            │
            ▼  (per-bot WSS for inbound + REST for outbound)
       feishu_bridge ─────WS─────►  channel_server  ◄────IRC────►  ergo (IRC server)
                                          │                                 │
                                          ▼                                 ▼
                                    PluginRegistry                     agent_mcp.py
                                     (mode, sla,                       (per-agent CC
                                      audit, csat,                     in zellij pane)
                                      activation, resolve)
```

A single `channel_server` process is the broker. Bridge processes (one per Feishu bot) connect via WebSocket and proxy messages bidirectionally. Agent processes (one per agent identity) connect via IRC. The plugin registry holds horizontal concerns: mode state, SLA timers, audit logging, CSAT surveys.

## 2. Key source files

| File | Role | LOC |
|---|---|---|
| [`src/channel_server/router.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/channel_server/router.py) | WS↔IRC bidirectional translation; `/cmd` dispatch; mode-dependent `@<entry_agent>` prefix | 194 |
| [`src/channel_server/routing.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/channel_server/routing.py) | `RoutingTable` + `Bot` + `ChannelRoute` dataclasses; V6 schema parser | 115 |
| [`src/channel_server/routing_watcher.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/channel_server/routing_watcher.py) | mtime poll → reload + IRC JOIN/PART diff | 103 |
| [`src/channel_server/plugin.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/channel_server/plugin.py) | Plugin protocol + `PluginRegistry` + command-conflict detection | 106 |
| [`src/channel_server/ws_server.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/channel_server/ws_server.py) | Bridge connection management; `BridgeConnection` registry | 108 |
| [`src/feishu_bridge/bridge.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/feishu_bridge/bridge.py) | Per-bot Feishu listener + dedup + outbound routing | 676 |
| [`src/feishu_bridge/routing_reader.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/feishu_bridge/routing_reader.py) | bot-scoped `routing.toml` filter; bridge stays decoupled from `channel_server.routing` | 96 |
| [`src/plugins/mode/plugin.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/plugins/mode/plugin.py) | copilot/takeover state machine; emits `mode_changed` events | 50 |
| [`src/plugins/sla/plugin.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/src/plugins/sla/plugin.py) | takeover-timeout + help-timeout asyncio timers | ~200 |

## 3. V6 `routing.toml` schema

This is the canonical source of truth at runtime — both `channel_server` and `feishu_bridge` load it.

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

## 4. Plugin model in 30 lines

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

That's the entire shape: declare commands, hold state in `self`, expose `query()`. Other plugins (sla, audit, csat) follow the same template. **The ergonomics here are what we want to match** in ESR — though using the OTP-native primitives instead of an imperative class. See [`04-target-design.md`](./04-target-design.md).

## 5. What we want from zchat (and why)

- **`routing.toml [bots]/[channels]` schema** — ops-friendly, single-file routing definition. ESR's split (`workspaces.yaml` + `adapters.yaml`) is harder to grok at a glance and requires consistency to be maintained between two files.
- **`mode` plugin (copilot/takeover)** — operator-takeover semantics is required for the customer-service workflows ESR will host. ESR has no analog today.
- **`sla / audit / csat / activation` plugins** — workflow primitives that compose with `mode`. Reusing zchat's design saves the cost of rediscovering edge cases (cancellation on mode change, late mode-changed events, breach-after-resolve race, etc.).
- **zellij launch model** — alternative to tmux for agent process orchestration. The fixture pattern in [`tests/pre_release/conftest.py`](https://github.com/ezagent42/claude-zchat-channel/blob/refactor/v4/tests/pre_release/conftest.py) (`capture_zellij_screenshot` + `zellij action dump-screen --pane-id <id>`) is structurally cleaner than tmux pane polling.
- **Auth model (extended form)** — zchat's single-token approach (`IRC_AUTH_TOKEN` env var) is too thin; ESR will replace with magic-link (human onboarding) + device-flow (headless bot pairing).

## 6. What we don't want from zchat

- **IRC-as-fabric** — ESR already has Phoenix.PubSub for inter-actor messaging. Adding IRC duplicates the fabric and adds an external runtime dependency (`ergo`).
- **WeeChat / ergo runtime dependencies** — extra processes ESR doesn't need.
- **Plugin imperative state model (verbatim)** — zchat's `class ModePlugin: self._modes = {}` works for zchat but conflicts with ESR's purity discipline. We adopt the *behavior* via projection tables, not the *mechanism*. See [`04-target-design.md`](./04-target-design.md) for the chosen alternative.

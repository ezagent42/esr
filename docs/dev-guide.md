# ESR v0.2 Developer Guide

## CLI installation (Phase 2, post-PR-2.5/2.6)

The `esr` CLI is now an Elixir-native escript built from `runtime/`.

```sh
cd runtime
mix escript.build
# Produces ./esr — copy to a directory on $PATH:
cp esr ~/.local/bin/esr     # or wherever your $PATH points
```

Or install system-wide via:
```sh
mix escript.install path/to/runtime
```

The escript talks to a running `esrd` over HTTP (`/admin/slash_schema.json`)
and through the admin queue files. No Python dependency required for the
core CLI surface: `esr exec`, `esr help`, `esr describe-slashes`,
`esr daemon`, `esr admin submit`, `esr notify`.

Migration note: 2026-05-06 — Python click CLI fully deleted. The
escript at `runtime/esr` (or `./esr.sh` wrapper) is the only operator
surface. Adapter / workspace registration runs via slash commands
through the admin queue.

## Getting started

1. Ensure a Feishu app exists and its bot is a member of the chat(s) you
   want to drive CC sessions from. Copy `app_id` and `app_secret`.
2. `bash scripts/esrd.sh start --instance=default`
3. `runtime/esr exec adapter_start type=feishu instance_id=feishu-prod \
       app_id=<app_id> app_secret=<app_secret>` (or `./esr.sh ...`).
4. `runtime/esr exec /new-workspace name=esr-dev role=dev \
       start_cmd=scripts/esr-cc.sh \
       chat_id=<chat_id> app_id=<app_id>`
5. In Feishu, DM the bot: `/new-session esr-dev name=root`
6. A tmux window `smoke-root` appears hosting a CC session with
   `esr-channel` MCP loaded. Subsequent messages to the bot (or with
   `@root <message>` prefix) get routed into that session's prompt.

## Writing a new handler

Handlers are pure functions `(state, event) -> (state', [Action])`.
They live in `handlers/<name>/src/esr_handler_<name>/on_msg.py` and
declare state shape via `@handler_state` and the message handler via
`@handler(actor_type=..., name="on_msg")`.

Minimal `/ping → pong` handler:

```python
from esr import Action, Emit, Event, handler, handler_state
from pydantic import BaseModel

@handler_state(actor_type="ping_proxy", schema_version=1)
class PingState(BaseModel):
    model_config = {"frozen": True}
    count: int = 0

@handler(actor_type="ping_proxy", name="on_msg")
def on_msg(state: PingState, event: Event) -> tuple[PingState, list[Action]]:
    if event.event_type == "msg_received" and event.args.get("content") == "/ping":
        return state.model_copy(update={"count": state.count + 1}), [
            Emit(adapter="feishu", action="send_message",
                 args={"chat_id": event.args["chat_id"], "content": "pong"})
        ]
    return state, []
```

Add tests in `handlers/ping/tests/test_on_msg.py` asserting the action
list matches your expectation.

## Writing a new adapter

Adapters bridge an external transport to ESR's event bus. They live
in `adapters/<name>/src/esr_<name>/adapter.py` and implement two
async methods: `on_inbound_loop()` (pulls from the external source,
emits `Event`s) and `on_directive(action, args)` (handles emit
directives from peers).

Minimal Slack-ish adapter sketch:

```python
from esr.adapter import Adapter, AdapterConfig, Event

class SlackAdapter(Adapter):
    def __init__(self, instance_id: str, config: AdapterConfig):
        self.bot_token = config["bot_token"]

    async def on_inbound_loop(self):
        async for msg in self._slack_rtm():
            yield Event(
                source=f"esr://localhost/adapter/slack/{self.instance_id}",
                event_type="msg_received",
                args={"chat_id": msg["channel"], "content": msg["text"]},
            )

    async def on_directive(self, action: str, args: dict) -> dict:
        if action == "send_message":
            await self._slack_post(args["chat_id"], args["content"])
            return {"ok": True}
        return {"ok": False, "error": f"unknown action: {action}"}
```

## Writing a new pattern

Patterns are declarative topologies — Python DSL that compiles to a
YAML artifact. They live in `patterns/<name>.py`.

Minimal single-node pattern:

```python
from esr import command, node

@command("hello")
def hello() -> None:
    node(
        id="hello:{{name}}",
        actor_type="ping_proxy",
        handler="ping.on_msg",
        params={"name": "{{name}}"},
    )
```

Invoke via `/new-session` (the topology DSL `esr cmd run` was P3-13-deleted
along with `Esr.Topology`; sessions are spawned via slash routes now).

## Debugging

- `esr actors list` — live peers with BEAM PIDs
- `esr actors inspect <id>` — state + chat_ids + default_chat_id
- `esr trace --last 5m` — telemetry ring
- `esr deadletter list` — failed handler calls
- `esr session chat-id <session_id>` — looked up from actor inspect

## Multi-app + cross-app reply (PR-A)

Every inbound carries `args.app_id` end-to-end and surfaces on the
`<channel app_id="cli_…">` attribute. The `mcp__esr-channel__reply`
tool requires explicit `app_id` — there is no default.

To forward to a different app:

```python
# CC, in tool-call form:
reply(
    chat_id="oc_target_chat",
    app_id="cli_other_app_id",      # different from inbound's app_id
    text="forwarded summary",
)
```

The runtime resolves `(chat_id, app_id) → workspace`, checks the
calling principal's `workspace:<target_ws>/msg.send` capability, and
hands off to the target FAA peer. Three structured denies
(`unknown_chat_in_app`, `forbidden`, `unknown_app`) all log
`FCP cross-app deny type=…`. `reply_to_message_id` and
`edit_message_id` are stripped automatically when source app ≠ target
app — they belong to the source app's message_id space.

See `docs/guides/writing-an-agent-topology.md` §三.5 for the full
chain. Cross-app E2E is `tests/e2e/scenarios/04_multi_app_routing.sh`.

## Topology + business-topology awareness (PR-C / PR-F)

Each CC session sees its 1-hop neighbours via the `<channel>` tag:

```xml
<channel ... workspace="ws_dev"
             user_id="ou_..."
             reachable='[{"uri":"workspace:ws_kanban","name":"kanban"},...]'>
  <message text…>
</channel>
```

`reachable=` is JSON-string (Claude Code only forwards flat
`[A-Za-z0-9_]+` attributes — see `docs/notes/actor-topology-routing.md`
§8 / `docs/notes/claude-code-channels-reference.md`).

For business-topology context (purpose, pipeline position, downstream
hand-off, expected format), CC calls
`mcp__esr-channel__describe_topology` — parameter-less; cc_mcp injects
`ESR_WORKSPACE` server-side. Operators populate
the workspace's `metadata:` field to feed it. Spec
`docs/superpowers/specs/2026-04-28-business-topology-mcp-tool.md`.

## CC session prompt prelude

Each `role/` subdirectory has a `CLAUDE.md` that becomes the prompt
prelude for that role's CC sessions:

- `roles/dev/CLAUDE.md` — developer-assistance sessions.
- `roles/diagnostic/CLAUDE.md` — diagnostic sessions (gated `_echo`
  MCP tool exposed, see `adapters/cc_mcp/src/esr_cc_mcp/tools.py`).

Repo-root `CLAUDE.md` is the primer for AI-pair-programming **on the
ESR repo itself** (test commands, gotchas, links). Don't conflate.

## Common gotchas

- Workspace config is stored per-workspace under
  `~/.esrd/<inst>/workspaces/<name>/workspace.json` (ESR-bound) or
  `<repo>/.esr/workspace.json` (repo-bound). See
  `docs/superpowers/specs/2026-05-06-workspace-vs-code-redesign.md`.
- `cc_tmux.new_session` start_cmd is relative to `adapter_runner` cwd
  (repo root); absolute paths are clearer.
- MCP connection failures show as `tool_result.error.type=esrd_disconnect`
  in the CC tool output; retry is the operator's job.
- `claude --resume <session_id>` requires the session id to exist in
  `~/.esrd/default/session-ids.yaml` — `esr-cc.sh` writes this on first
  spawn and reads it on restart.
- `metadata:` in a workspace's `workspace.json` is exposed verbatim to
  the LLM via `describe_topology` — never put secrets there. Use `env:`
  (filtered at the response boundary) or `cwd:` (also filtered).
- `notifications/claude/channel` only forwards attributes matching
  `[A-Za-z0-9_]+`. Nested children are silently dropped; encode list
  attrs as JSON strings (`reachable=` precedent).

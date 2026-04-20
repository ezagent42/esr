# ESR v0.2 Developer Guide

## Getting started

1. Ensure a Feishu app exists and its bot is a member of the chat(s) you
   want to drive CC sessions from. Copy `app_id` and `app_secret`.
2. `bash scripts/esrd.sh start --instance=default`
3. `uv run --project py esr adapter add feishu-prod --type feishu \
       --app-id <app_id> --app-secret <app_secret>`
4. `uv run --project py esr workspace add esr-dev \
       --cwd ~/Workspace/esr --start-cmd scripts/esr-cc.sh \
       --role dev --chat <chat_id>:<app_id>:dm`
5. In Feishu, DM the bot: `/new-session esr-dev tag=root`
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

Invoke it via `esr cmd run hello --param name=world`.

## Debugging

- `esr actors list` — live peers with BEAM PIDs
- `esr actors inspect <id>` — state + chat_ids + default_chat_id
- `esr trace --last 5m` — telemetry ring
- `esr deadletter list` — failed handler calls
- `esr session chat-id <session_id>` — looked up from actor inspect

## Common gotchas

- `workspaces.yaml` lives at `~/.esrd/default/workspaces.yaml`; v0.2 is
  not yet per-instance-aware in the CLI.
- `cc_tmux.new_session` start_cmd is relative to `adapter_runner` cwd
  (repo root); absolute paths are clearer.
- MCP connection failures show as `tool_result.error.type=esrd_disconnect`
  in the CC tool output; retry is the operator's job.
- `claude --resume <session_id>` requires the session id to exist in
  `~/.esrd/default/session-ids.yaml` — `esr-cc.sh` writes this on first
  spawn and reads it on restart.

# PR-9 T11b progress snapshot (2026-04-24)

**Scope**: Wire real Claude CLI + cc_mcp stdio bridge into ESR's session
pipeline so inbound Feishu messages reach CC as `<channel>` tags via
MCP notifications, and CC's `reply` / `react` / `send_file` MCP tools
round-trip back through FCP → FeishuAppProxy → FeishuAppAdapter →
Feishu REST.

**Status**: 13/13 structural tasks merged. Live E2E scenario-01 green
from head is deferred (structural wiring + unit coverage complete).

## PRs merged

| # | Task | Summary |
|---|------|---------|
| #35 | T11b.0 | Design doc + notes + `.env.local` bootstrap |
| #36 | T11b.0a | common.sh exports `ESR_BOOTSTRAP_PRINCIPAL_ID` |
| #37 | T11b.1 | `Workspaces.Registry.workspace_for_chat/2` reverse lookup |
| #38 | T11b.2 | `SessionRouter.enrich_params/2` threads session_id + workspace_name |
| #39 | T11b.5 | `FeishuAppAdapter.wrap_as_directive` maps `send_file` |
| #40 | T11b.4a | `ChannelChannel.join/3` rejects duplicate session_id joins |
| #41 | T11b.4b | cc_mcp declares `claude/channel` + emits `notifications/claude/channel` |
| #42 | T11b.6a | FCP emits 3-tuple `{:text, text, %{message_id, sender_id, thread_id}}` |
| #43 | T11b.6 | `CCProcess.SendInput` broadcasts on `cli:channel/<sid>` pubsub |
| #44 | T11b.4 | FCP registers as `thread:<sid>` + handles 6-tuple `:tool_invoke` |
| #45 | T11b.3 | `TmuxProcess` launches `claude` CLI + renders per-session MCP config |
| #46 | T11b.7 | Real `cc_adapter_runner.on_msg` returns `SendInput` |
| #47 | T11b.8 | CCProcess drops `:tmux_output` + test-env claude-launch guard |

## Architecture outcome

```
User types in Feishu
  └─ mock_feishu /push_inbound
  └─ feishu_adapter_runner (py) → Phoenix /adapter_hub/socket
  └─ EsrWeb.AdapterChannel → FeishuAppAdapter (elixir)
  └─ SessionRegistry.lookup_by_chat_thread → FCP pid
  └─ send(fcp, {:feishu_inbound, envelope})
  └─ FCP.handle_upstream
      └─ slash? → AdminSession.SlashHandler
      └─ else → send(cc_process, {:text, text, %{message_id, sender_id, thread_id}})
  └─ CCProcess.invoke_and_dispatch
      └─ HandlerRouter.call("cc_adapter_runner.on_msg", ...)
      └─ handler returns [SendInput(text=event.args["text"])]
  └─ CCProcess.dispatch_action({type: "send_input"})
      └─ Phoenix.PubSub.broadcast("cli:channel/<sid>", {:notification, envelope})
  └─ EsrWeb.ChannelChannel.handle_info → push(socket, "envelope", envelope)
  └─ cc_mcp WS receives → writes notifications/claude/channel to stdio
  └─ Claude Code injects <channel source="feishu" ...> into CC's context
  └─ CC turns; calls reply/react/send_file MCP tool
  └─ cc_mcp tool handler → ws.push({kind: "tool_invoke", ...})
  └─ EsrWeb.ChannelChannel.handle_in
      └─ Registry.lookup(Esr.PeerRegistry, "thread:<sid>") → FCP pid
      └─ send(fcp, {:tool_invoke, req_id, tool, args, channel_pid, principal_id})
  └─ FCP.handle_info({:tool_invoke, ...})
      └─ dispatch_tool_invoke: reply → outbound directive send_message
  └─ emit_to_feishu_app_proxy → FeishuAppProxy → FeishuAppAdapter
  └─ FeishuAppAdapter.handle_downstream
      └─ wrap_as_directive (T10/T11b.5): kind=reply → action=send_message
      └─ EsrWeb.Endpoint.broadcast("adapter:feishu/<instance>", "envelope", directive)
  └─ Python feishu_adapter_runner directive_loop
      └─ adapter.on_directive("send_message", args)
      └─ HTTP POST open.feishu.cn/open-apis/im/v1/messages
```

## Structural anti-pattern closed

Pre-T11b, three different peer types all hit variants of the "nobody
spawns X worker" class:

- PR-8: SlashHandler wasn't boot-spawned → bootstrap added
- T10: FeishuAppAdapter Elixir peer wasn't boot-spawned → bootstrap added
- T11a: cc_adapter_runner handler worker wasn't boot-spawned → 
  `Esr.Application.restore_handlers_from_disk/1` walks agents.yaml
  `capabilities_required`, extracts `handler:<mod>/*`, calls
  `WorkerSupervisor.ensure_handler` for each unique module

Every capability-declared handler now has a boot spawn. The pattern is
no longer individually-enumerated; it's derived from yaml
declarations. Future handler additions require no Elixir code change
to boot-spawn.

## Tests

- **Elixir**: 487 tests, 0 failures on a clean run (flakes
  documented in `docs/notes/`; not triggered when suite runs standalone).
- **Python**: 592 passed, 1 skipped.
- **Leaked claude processes** (after `mix test`): 0 — T11b.8 guard
  confirmed.
- **E2E scenario 01**: steps 1 + 2 proven by subagent research across
  T11b.3 through T11b.7. Full step 2 "real CC replies 'ack'" gate
  needs a live claude turn and is follow-up.

## Notes / references surfaced

- `docs/notes/claude-code-channels-reference.md` — Claude Code channel
  contract captured from official docs (required for future readers
  who'll ask the same questions about `--dangerously-load-development-channels`,
  `experimental_capabilities`, permission relay)
- `docs/notes/mcp-transport-orphan-session-hazard.md` — 2026-04-24 live
  incident RCA (2 MCP clients silently shadowed each other on
  `cc:linyilun.root`; T11b.4a rejection logic directly addresses this)
- `docs/futures/admin-principal-id-bind-cli.md` — long-term direction
  for auto-generated admin principal + IM-binding CLI; `.env.local`
  (T11b.0) is the acknowledged short-term workaround

## Follow-ups (not in T11b)

1. **Live E2E smoke from head** — run scenario 01 end-to-end with
   real claude CLI + assert sent_messages contains "ack" (CC's reply
   per the scenario prompt). Structural wiring complete; needs a
   dedicated session to run + debug any first-contact issues.
2. **Permission relay** (`claude/channel/permission`) — optional
   capability; forward Bash/Write/Edit approval prompts to Feishu.
   Worth it for production; blocked on sender-allowlist audit.
3. **Multi-chat `ESR_CHAT_IDS`** — shape-supports multiple
   `{chat_id, app_id, kind}` entries but only exercised with single.
   Revisit alongside scenario 02.

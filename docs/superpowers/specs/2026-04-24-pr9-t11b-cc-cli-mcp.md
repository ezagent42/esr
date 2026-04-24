# PR-9 T11b Design — Real Claude CLI + cc_mcp MCP Bridge

**Status:** DRAFT (reviewed by code-reviewer subagent 2026-04-24; awaiting user sign-off)

**Review trail:** First-pass review caught (1) factual inaccuracy in §3 about `session_id` — already generated, only threading was missing; fixed. (2) tmux `-C` + shell-command semantics — clarified argv-as-one-shell-string convention. (3) Notification envelope shape — canonicalised to match cc_mcp's branching. (4) FCP → CCProcess upstream tuple needs enrichment (`message_id`, `sender_id`) — added work item T11b.6a. (5) Ordering race between CCProcess broadcast and cc_mcp join — added mitigation to §8. (6) Several open questions resolved inline; remaining unknowns moved to §9a.

**User-review amendments (2026-04-24)**: (a) §4.2 A corrected — pane runs
`claude --mcp-config …`, NOT `python -m esr_cc_mcp.channel` directly; cc_mcp
is a stdio subprocess claude spawns per the mcp-config file. Matches
cc-openclaw.sh lines 275-284. (b) §9 resolves `ESR_BOOTSTRAP_PRINCIPAL_ID`:
fresh-install fallback for capabilities-file-missing AND as the default
`principal_id` when cc_mcp's `tool_invoke` arrives before `session_register`.
E2E adds a pre-check (T11b.0a) to export it in `common.sh`. (c) §9 adds the
dup-join hazard from the live 2026-04-24 orphan-transport incident (captured
in `docs/notes/mcp-transport-orphan-session-hazard.md`); §5 gains work item
T11b.4a to harden `ChannelChannel.join/3` against silent last-writer-wins.

**User-review amendments round 2 (2026-04-24)**: (d) `--dangerously-load-development-channels
server:esr-channel` IS required — earlier draft wrongly called it cc-openclaw-specific. Per
https://code.claude.com/docs/en/channels-reference the flag bypasses Anthropic's research-preview
allowlist for ANY non-approved channel, including ESR's. (e) New work item T11b.4b: current
`cc_mcp` passes `experimental_capabilities={}` at `channel.py:211`, which makes it a plain MCP
server — NOT a channel. Must declare `{"claude/channel": {}}` so Claude Code registers the
notification listener and our inbound events appear as `<channel source="esr-channel" ...>` tags.
Reference notes captured in `docs/notes/claude-code-channels-reference.md` including a pointer
to permission-relay as a post-T11b follow-up.
**Author:** Claude Opus 4.7 (via T11b.0 design-doc-first workflow)
**Scope:** Production CC round-trip — real `claude` CLI running in tmux, `cc_mcp` stdio bridge, esr-channel WebSocket.
**Supersedes:** T11a placeholder `cc_adapter_runner.on_msg` (returns canned `"ack: <text>"`)
**Reference:** `cc-openclaw/channel_server/adapters/cc/channel.py` (working implementation of the same pattern).

---

## 1. Context

T11a proved the Feishu → ESR routing chain by adding a stub `cc_adapter_runner.on_msg` handler that returns `[Reply(text="ack: <received>")]`. Scenario-01 steps 1–3 are green; step 4 (`send_file`) fails because the placeholder can't emit files.

T11b wires the real CC interactive pipeline:

- `TmuxProcess` launches `claude` CLI inside its pane, not an empty shell.
- CC is launched with an MCP config pointing at `cc_mcp` as a stdio server.
- `cc_mcp` reads session-scoped env vars, opens a WebSocket back to ESR's `/channel/socket` endpoint, and exposes `reply`/`react`/`send_file` MCP tools.
- Inbound user text (Feishu → FCP → CCProcess) is delivered to CC through the **MCP notification** stream (not tmux stdin) — CC sees it as a message to respond to.
- CC's tool calls round-trip back through `cc_mcp` → WS → `EsrWeb.ChannelChannel` → FCP → FeishuAppAdapter → Feishu REST.

User principle (2026-04-24): *"不应该靠 tmux_proxy 捕获 stdout 返回来实现 CC response 的回传，而应该通过 esr-channel 来回传消息"*. This design honours that.

## 2. Reference Architecture (cc-openclaw)

```
┌───────────────────────────────────────────────────────────────────┐
│ tmux window                                                       │
│                                                                   │
│   claude CLI (interactive)                                        │
│      ↕ stdio (MCP JSON-RPC)                                       │
│   cc_mcp channel.py  ──(async task group, anyio)──▶               │
│      ├─ Server.run()           MCP protocol handler               │
│      ├─ EsrWSClient.connect()  ws://…/channel/socket              │
│      └─ consume_messages()     inbound pump ← WS                  │
└──────────────────────────────┬────────────────────────────────────┘
                               │ WebSocket
                               ▼
┌───────────────────────────────────────────────────────────────────┐
│ ESR runtime (Elixir)                                              │
│   EsrWeb.ChannelSocket  /channel/socket                           │
│   EsrWeb.ChannelChannel topic cli:channel/<session_id>            │
│     • on_join         → register in SessionSocketRegistry          │
│     • "envelope"      → kind=session_register | tool_invoke        │
│     • tool_invoke     → send to thread:<session_id> peer           │
│   FCP / FeishuAppProxy / FeishuAppAdapter (existing downstream)    │
└───────────────────────────────────────────────────────────────────┘
```

Three key cc-openclaw patterns to mirror:

1. **Tool handlers are sync but dispatch async** — `asyncio.run_coroutine_threadsafe(send_reply(…), loop)` bridges MCP's sync tool-call convention to async WS sends.
2. **Inbound = MCP notifications, not tool results** — server pushes `notifications/claude/channel` into CC's write stream. Lets unbounded message flow without blocking tool dispatch.
3. **Env var bootstrap** — no config file parsing in the CC subprocess; everything (session_id, chat_ids, workspace) arrives as env vars injected at tmux launch.

## 3. Current ESR State (T11b.0 research)

### Already exists

- **`adapters/cc_mcp`** — fully scaffolded. Reads `ESR_SESSION_ID`, `ESR_WORKSPACE`, `ESR_CHAT_IDS`; opens WS to `EsrWeb.ChannelSocket`; exposes `reply`/`send_file` MCP tools; handles inbound via a `notification` envelope kind.
- **`EsrWeb.ChannelSocket` + `EsrWeb.ChannelChannel`** at `/channel/socket` — join validates session_id, registers chats in `SessionSocketRegistry`, routes `tool_invoke` envelopes to `thread:<session_id>` peers in `PeerRegistry`.
- **`TmuxProcess`** — opens a tmux control-mode client with `tmux -C new-session …`; parses `%output/%begin/%end/%exit` frames; forwards `{:tmux_output, bytes}` upstream to `cc_process` neighbor.

### Gaps (what T11b fills)

| Gap | File | Symptom today |
| --- | --- | --- |
| TmuxProcess doesn't inject ESR_* env vars | `runtime/lib/esr/peers/tmux_process.ex` `os_env/1` returns `[]` | cc_mcp crashes with `KeyError: 'ESR_SESSION_ID'` |
| TmuxProcess doesn't launch any command in the pane | `os_cmd/1` returns `tmux -C new-session -s N -c DIR` without a trailing command arg | pane shows an idle shell prompt — CC never starts |
| SessionRouter doesn't thread `session_id` / `workspace_name` into `spawn_args` | `SessionRouter.do_create/1` generates `session_id` (`session_router.ex:331 gen_id/0`) but `spawn_args/3` (~l.619) passes `params` to the impl callback without adding `session_id`; `workspace_name` is never fetched | TmuxProcess gets `%{session_name, dir}` only; no way to build ESR_* env vars |
| No `:tool_invoke` consumer on FCP | `FeishuChatProxy` handles `:reply` from CCProcess but not `:tool_invoke` from `ChannelChannel` | CC's `reply` MCP tool would be dropped |
| SessionSocketRegistry peer target isn't wired to FCP | `ChannelChannel` looks up peer by `"thread:" <> session_id` in `PeerRegistry` — no peer registers under that name today | tool_invoke envelope has no addressable target |
| No integration test for CC-in-tmux round-trip | — | regression window wide open |

## 4. Target Design

### 4.1 Data flow

```
User types "hello" in Feishu
  ├─▶ mock_feishu /push_inbound
  ├─▶ feishu_adapter_runner (py)
  │     └─▶ Phoenix /adapter_hub/socket, event envelope on adapter:feishu/<instance>
  ├─▶ EsrWeb.AdapterChannel
  ├─▶ FeishuAppAdapter.handle_upstream
  │     └─▶ SessionRegistry.lookup_by_chat_thread → session pid
  │     └─▶ send(feishu_chat_proxy, {:feishu_inbound, envelope})
  ├─▶ FeishuChatProxy.handle_upstream
  │     └─▶ send(cc_process, {:text, "hello"})
  ├─▶ CCProcess.invoke_and_dispatch
  │     └─▶ HandlerRouter.call("cc_adapter_runner.on_msg", payload)
  │     └─▶ [T11b replacement] handler returns [SendInput(text="hello")]
  │                             ← shorthand for "push to CC via the MCP
  │                                notification channel, not tmux stdin"
  ├─▶ CCProcess.dispatch_action({type: "send_input", text})
  │     └─▶ [T11b NEW] route to ChannelChannel pubsub topic
  │                     cli:channel/<session_id>, kind=notification
  ├─▶ Phoenix broadcasts to cli:channel/<session_id>
  ├─▶ cc_mcp WS receives envelope
  │     └─▶ inject_message → CC sees a notifications/claude/channel frame
  ├─▶ CC reads "hello", decides to respond
  ├─▶ CC calls reply(chat_id, text="got it") MCP tool
  ├─▶ cc_mcp tool handler → asyncio.run_coroutine_threadsafe(send_reply(…))
  ├─▶ ws.push("envelope", {kind: "tool_invoke", tool: "reply", args, req_id})
  ├─▶ EsrWeb.ChannelChannel.handle_in("envelope", …)
  │     └─▶ [T11b NEW] lookup thread:<session_id> → FCP pid
  │     └─▶ send(fcp_pid, {:tool_invoke, req_id, "reply", args, channel_pid})
  ├─▶ FCP.handle_info({:tool_invoke, …})
  │     └─▶ [T11b NEW] dispatch by tool → emit {:outbound, envelope} to
  │                     feishu_app_proxy (reuses T11a wrap_as_directive path)
  ├─▶ FeishuAppAdapter.handle_downstream → directive on adapter:feishu/<inst>
  ├─▶ feishu_adapter_runner.on_directive → adapter._send_message
  └─▶ mock_feishu.sent_messages ← "got it" ✓
```

### 4.2 Component changes

#### A. `TmuxProcess` — env + start_cmd (claude CLI, not cc_mcp directly)

**Reference — cc-openclaw.sh lines 275-284** (the working precedent):

```bash
CLAUDE_CMD="cd $SCRIPT_DIR && [ -f cc-openclaw.local.sh ] && source cc-openclaw.local.sh;"
CLAUDE_CMD="$CLAUDE_CMD OC_CHAT_ID=$CHAT_ID OC_USER=$CLI_TARGET OC_ROLE=$ROLE OC_SESSION=$CLI_SESSION"
[ -n "$CLI_TAG" ] && CLAUDE_CMD="$CLAUDE_CMD OC_TAG=$CLI_TAG"
CLAUDE_CMD="$CLAUDE_CMD claude --permission-mode bypassPermissions"
CLAUDE_CMD="$CLAUDE_CMD --dangerously-load-development-channels server:openclaw-channel"
CLAUDE_CMD="$CLAUDE_CMD --mcp-config .mcp.json"
CLAUDE_CMD="$CLAUDE_CMD --add-dir $WORKSPACE_DIR"
[ -f "$SCRIPT_DIR/$SETTINGS_FILE" ] && CLAUDE_CMD="$CLAUDE_CMD --settings $SETTINGS_FILE"

tmux new-window -t "$SESSION_NAME" -n "$WINDOW_NAME" "$CLAUDE_CMD"
```

with `.mcp.json`:

```json
{"mcpServers": {"openclaw-channel": {"command": "uv", "args": ["run", "python3", "channel_server/adapters/cc/channel.py"]}}}
```

**Earlier-draft correction** (spec review feedback 2026-04-24): the pane's
initial process is **`claude`** (the CC CLI), NOT `cc_mcp` directly. cc_mcp is
a *stdio MCP server* that claude launches internally as a subprocess, wired up
via the `--mcp-config` file. Running `python -m esr_cc_mcp.channel` directly
in the pane would start the stdio server with nothing attached to its stdin,
and there'd be no claude CLI to issue tool calls.

**ESR T11b adaptation of the cc-openclaw recipe**:

- `spawn_args/1` accepts new params: `session_id`, `workspace_name`, `chat_id`,
  `app_id`, `start_cmd`. Default `start_cmd` is the claude CLI invocation:
  ```
  claude --permission-mode bypassPermissions
         --dangerously-load-development-channels server:esr-channel
         --mcp-config /tmp/esr-mcp-<session_id>.json
         --add-dir <workspace.cwd>
         [--settings <workspace.settings_file>]
  ```
  **Correction** (user review 2026-04-24, citing
  https://code.claude.com/docs/en/channels-reference):
  `--dangerously-load-development-channels server:<name>` IS required for
  ESR's channel too. It's not cc-openclaw-specific — the flag bypasses
  Anthropic's research-preview allowlist for any user-built channel, and
  every ESR deployment (until our channel is formally approved) needs it.
  `server:esr-channel` matches the `mcpServers.esr-channel` key in our
  rendered `.mcp.json`. See `docs/notes/claude-code-channels-reference.md`
  for the full contract.

- Per-session `.mcp.json` rendered to `/tmp/esr-mcp-<session_id>.json` at
  TmuxProcess init, pointing at the ESR cc_mcp module:
  ```json
  {"mcpServers": {"esr-channel": {
      "command": "uv",
      "args": ["run", "--project", "<repo>/adapters/cc_mcp",
               "python", "-m", "esr_cc_mcp.channel"]
  }}}
  ```
  The env vars the cc_mcp subprocess needs (ESR_SESSION_ID / ESR_WORKSPACE /
  ESR_CHAT_IDS / ESR_ESRD_URL) are inherited from the claude parent — which
  gets them from the tmux pane env — which `TmuxProcess.os_env/1` supplies.

- `os_env/1` emits:
  ```elixir
  [
    {"ESR_SESSION_ID", session_id},
    {"ESR_WORKSPACE", workspace_name},
    {"ESR_CHAT_IDS", Jason.encode!([%{chat_id: chat_id, app_id: app_id, kind: "feishu"}])},
    {"ESR_ESRD_URL", ws_url}         # explicit; bypasses port-file discovery
  ]
  ```

- `os_cmd/1` appends the full claude invocation as a single shell-command
  argument to tmux's `new-session`:
  `[…, "new-session", "-s", name, "-c", dir, claude_invocation_as_one_string]`.
  The shell-command string is built via `Enum.join(argv, " ")` so tmux hands
  it to `/bin/sh -c` (tmux's new-session positional semantics).

**Why Option A (inline command), not send-keys**: atomic with session creation (no race where the pane is ready but the command hasn't been typed yet), no shell-escaping pitfalls in a second `send-keys` call, exit code of the CC process becomes tmux session exit → natural teardown.

**`tmux -C new-session … <shell-command>` semantics to respect** (reviewer
clarification): tmux takes the trailing positional as a single `shell-command`
string, evaluated as `/bin/sh -c "<string>"`. Passing it as multiple argv
elements causes tmux to glob them with spaces — usually fine, but one quoted
argv is safer. So `os_cmd/1` should emit:
`[…, "new-session", "-s", name, "-c", dir, Enum.join(start_cmd_argv, " ")]`
and the single argument is a ready-to-shell string. Also: the child inherits
tmux's per-pane PTY (not erlexec's), so `use Esr.OSProcess, wrapper: :pty`
is orthogonal to CC's TTY needs. The integration test (§6) must explicitly
assert `claude` is running in the pane after init — don't rely on the tmux
session being alive as a proxy.

#### B. `SessionRouter` — params threading

`SessionRouter.do_create(params)` currently has `chat_id`, `thread_id`, `app_id` but no `workspace_name`. Add a lookup:

```elixir
workspace_name =
  params[:workspace_name] || Esr.Workspaces.Registry.workspace_for_chat(chat_id, app_id) || "default"
```

(`workspace_for_chat/2` is a new helper that iterates `workspaces.yaml`
entries and searches each workspace's `chats:` **list of maps** for a match
on `(chat_id, app_id)` — `chats` is `[{chat_id, app_id, kind}]` not a map,
so this is a linear scan, not a `get_in`. Symmetric to the Python adapter's
`_workspace_of`.)

Pass `session_id`, `workspace_name` through `spawn_args(impl, spec, params)` — already the thread that peers consume their init config from.

#### C. `FeishuChatProxy` — tool_invoke consumer

Add `handle_info({:tool_invoke, req_id, tool, args, channel_pid}, state)` that:

- Matches `tool` against the MCP surface.
- For `"reply"`: emit `{:outbound, %{kind: "reply", args: %{chat_id: state.chat_id, text: args["text"]}}}` to `feishu_app_proxy` — reuses T10/T11a directive-wrap path.
- For `"send_file"`: emit `{:outbound, %{kind: "send_file", args: %{chat_id, file_path: args["file_path"]}}}`. Extend `FeishuAppAdapter.wrap_as_directive/2` to map `send_file → send_file` (with `chat_id` + upload details; Python adapter already has `_send_file_mock` / `_send_file`).
- For `"react"`: pass through.
- On success, reply back on `channel_pid` with `{:envelope, %{kind: "tool_result", req_id, result: …}}` so CC's pending future resolves.

#### D. `EsrWeb.ChannelChannel` — thread peer lookup

Already routes `tool_invoke` to `thread:<session_id>` peer. T11b needs FCP to register there. Add to `FeishuChatProxy.init/1`:

```elixir
Registry.register(Esr.PeerRegistry, "thread:" <> session_id, nil)
```

This makes FCP addressable as `thread:<session_id>` — matches what ChannelChannel already looks up.

#### E. `CCProcess` — `SendInput` dispatch via pubsub, not tmux

Today `dispatch_action({type: "send_input"})` sends to `tmux_process` neighbor. For T11b, change the contract: `send_input` goes to the `cli:channel/<session_id>` Phoenix pubsub topic with kind=`notification`, not to tmux. The tmux pane's CC subprocess receives it via its MCP notification stream (cc_mcp injects to CC).

Rationale: tmux stdin writes are fragile (cursor positioning, control-mode side effects, terminal-size dependencies). MCP notifications are the designed channel for "push a message into CC's context".

**Envelope shape** — the publisher envelope must match what
`cc_mcp/channel.py` expects (see `channel.py:100-126` which branches on `kind`
and `channel.py:_format_channel_tag`). Canonical notification:

```elixir
%{
  "kind" => "notification",
  "source" => "feishu",         # adapter family (cc_mcp tags the channel)
  "chat_id" => state.chat_id,
  "thread_id" => state.thread_id,
  "message_id" => message_id,   # from the FCP envelope
  "user" => sender_open_id,     # from the FCP envelope
  "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
  "content" => text
}
```

**Extra propagation work** (reviewer catch): FCP currently sends
`{:text, text}` (2-tuple) to CCProcess and strips the rest of the envelope.
For the notification shape, CCProcess needs `message_id`, `sender_id`,
`thread_id`. Extend the upstream message to
`{:text, text, %{message_id, sender_id, thread_id}}` so CCProcess can build
the full notification. This adds ~50 LOC across FCP + CCProcess + their
tests and is now work item **T11b.6a** (extracted).

**Admin-side precedent**: `Esr.Admin.Commands.Session.BranchEnd`
(`branch_end.ex:224-243`) already broadcasts on `cli:channel/<session_id>`
with a different kind (`cleanup_check_requested`). T11b mirrors the same
broadcast shape, just with `kind: "notification"`.

(Tmux output capture is still wired for *diagnostic* use — `{:tmux_output, bytes}` still flows upstream for the handler to observe, but it's no longer the primary transport. When `claude` CLI is the pane process, tmux_output carries CC's TUI chrome — the handler should filter or rate-limit to avoid flooding.)

#### F. `cc_adapter_runner.on_msg` — real handler

Replace T11a placeholder with:

```python
def on_msg(state, event):
    if event.event_type == "text":
        return state, [SendInput(text=event.args["text"])]
    return state, []
```

`SendInput` now routes to the channel pubsub (per change E), so the user text appears in CC's conversation. CC's own decision to `reply` closes the loop.

## 5. Work Items (ordered)

| # | Scope | Files | Test |
|---|-------|-------|------|
| T11b.1 | `workspace_for_chat/2` helper | `runtime/lib/esr/workspaces/registry.ex` | unit test |
| T11b.2 | `SessionRouter` threads `workspace_name` | `runtime/lib/esr/session_router.ex` | existing T6 test updated |
| T11b.3 | `TmuxProcess` env + start_cmd | `runtime/lib/esr/peers/tmux_process.ex` | tmux_process_test with ESR_* env assertions |
| T11b.4 | `FCP` registers `thread:<sid>` + handles `:tool_invoke` | `runtime/lib/esr/peers/feishu_chat_proxy.ex` + test | fcp_test_tool_invoke.exs |
| T11b.4a | `EsrWeb.ChannelChannel.join/3` rejects duplicate session_id join (closes orphan-transport hazard, see `docs/notes/mcp-transport-orphan-session-hazard.md`) | `runtime/lib/esr_web/channel_channel.ex` | new test: second join on same topic → `{:error, %{reason: "already_joined"}}` |
| T11b.4b | `cc_mcp` declares `claude/channel` capability + emits `notifications/claude/channel` on inbound (see `docs/notes/claude-code-channels-reference.md`) — currently passes `experimental_capabilities={}` so Claude Code doesn't route notifications | `adapters/cc_mcp/src/esr_cc_mcp/channel.py` (line 211 `experimental_capabilities` + `_handle_inbound`) | `adapters/cc_mcp/tests/test_channel_capability.py` (asserts capability + notification method name) |
| T11b.5 | `FeishuAppAdapter.wrap_as_directive` — add `send_file` | `runtime/lib/esr/peers/feishu_app_adapter.ex` | faa_test `send_file` directive shape |
| T11b.6 | `CCProcess.SendInput` → pubsub notification | `runtime/lib/esr/peers/cc_process.ex` | cc_process_test: send_input emits notification |
| T11b.6a | **Upstream envelope propagation** — FCP emits 3-tuple `{:text, text, %{message_id, sender_id, thread_id}}`; CCProcess consumes richer shape | `runtime/lib/esr/peers/feishu_chat_proxy.ex` + `cc_process.ex` | fcp_test + cc_process_test updates |
| T11b.7 | Replace placeholder `cc_adapter_runner.on_msg` | `handlers/cc_adapter_runner/src/.../on_msg.py` | existing handler test updated |
| T11b.8 | E2E gate: scenario 01 steps 4 + 5 (combined — single E2E covers send_file sha256 + second-message persistence, since both need full CC round-trip) | `tests/e2e/scenarios/01_single_user_create_and_end.sh` | manual run — sha256 + `cc:single` actor list both green |
| T11b.9 | Documentation: update spec `§FeishuChatProxy` + add `§cc_mcp` + `§TmuxProcess env model` | `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` | — |

**Ordering notes (reviewer catch)**: items T11b.3 → T11b.4 → T11b.5 → T11b.6 → T11b.6a → T11b.7 are all prerequisites for the E2E gate (T11b.8). The first manually-runnable end-to-end check is post-T11b.7. `T11b.5` is a small Elixir wrap — the Python `feishu_adapter_runner` side already has `on_directive("send_file", …)` wired (verified by `py/tests/adapter_runners/test_feishu_send_file.py`), so only the Elixir `build_directive` mapping is missing.

## 6. Tests

- **Unit — Python**: `cc_mcp` loads env vars, builds correct WS URL, inbound notification injection shape, tool_invoke envelope shape. Most already covered by `adapters/cc_mcp/tests`.
- **Unit — Elixir**: FCP `:tool_invoke` dispatch matrix (reply/react/send_file), TmuxProcess env var construction, ChannelChannel thread-lookup happy + miss paths.
- **Integration — Elixir**: new `runtime/test/esr/integration/cc_mcp_roundtrip_test.exs` that spawns a session with a mock cc_mcp (stubs out the `claude` CLI launch; just runs cc_mcp directly with fixed env vars), fires a `{:text, "hi"}` upstream, asserts a `tool_invoke kind=reply` arrives at the mock feishu_app_proxy.
- **E2E**: scenario 01 steps 1-5 all green. Step 6 (`/end-session`) is slash-parsing, out of T11b scope.

## 7. Deferrals

- **Real `claude` CLI binary check**: design assumes `claude` is on `PATH` inside the tmux session. A boot-time probe warning if not found can land as a tiny follow-up; not blocking.
- **Per-session MCP config file vs inline args**: start with inline `--mcp-config` pointing at `adapters/cc_mcp`. Config-file rendering per session is deferred until we need per-session MCP tool filtering.
- **Multi-chat `ESR_CHAT_IDS`**: list is supported but tested only with a single chat. Multi-chat support lands when scenario 02 (two users concurrent) is wired.
- **Live Feishu (non-mock) send_file**: `FeishuAdapter._send_file` already has a live path via `lark_oapi`; T11b covers the adapter wrapping, not the live adapter itself.

## 8. Risks & Pitfalls (from cc-openclaw experience)

1. **Tool dispatch deadlock**: MCP tool handlers are sync; if we don't `asyncio.run_coroutine_threadsafe` the WS send, the whole stdio bridge hangs. Mirror cc-openclaw's pattern exactly.
2. **MCP notification schema drift**: inbound injection must match `JSONRPCNotification + SessionMessage` — CC silently drops malformed frames. `adapters/cc_mcp` already has this right; don't regress it.
3. **Feishu echo loops**: if the reply-roundtrip's outbound message gets re-ingested as inbound (mock_feishu emits it back on `/ws`), we'd loop forever. mock_feishu's `_on_create_message` doesn't push to `_ws_clients` (it only records in `sent_messages`), so we're safe — but an integration test asserting no echo is worth adding.
4. **tmux -C exits without PTY on macOS**: already worked around in PR-3 via erlexec `:pty` wrapper; verify the child `claude` process inherits the PTY.
5. **Reconnect storm**: cc_mcp retries WS every 3s if the server drops. During esrd restart (e.g. compile reload), expect a brief burst. Acceptable.
6. **workspace lookup fallback**: if `workspace_for_chat/2` returns nil and we default to `"default"`, the CC process starts but Lane A authorization may fail. Fail loudly (log a clear warning) instead of silent default.
7. **tmux window naming**: cc-openclaw hit a dot-in-name bug. ESR's session naming (`esr_cc_<N>`) avoids this; keep it.
8. **Auto-create ordering race (reviewer catch)**: `SessionRouter.do_create` spawns peers synchronously. TmuxProcess.init launches `tmux -C new-session <CC-launch-cmd>` before the caller returns. `claude` + cc_mcp start in the pane; cc_mcp opens its WS and joins `cli:channel/<sid>`. Meanwhile `SessionRouter.redeliver_triggering_envelope/3` (`session_router.ex:224`) sends the triggering `{:text, "hello"}` to FCP, which forwards to CCProcess, which broadcasts on `cli:channel/<sid>` — **possibly before cc_mcp has joined**. `Phoenix.PubSub.broadcast` silently no-ops when there are no subscribers. Mitigation: CCProcess buffers `:send_input`-sourced notifications in state and replays on receipt of a `{:channel_joined, sid}` PubSub event that `EsrWeb.ChannelChannel.join/3` broadcasts. Alternative: cc_mcp client buffers post-join. Both acceptable; prefer Elixir-side because the runtime owns ordering guarantees for the pipeline. Worth a dedicated unit test.

## 9. Resolved Questions (post-review)

- **CC CLI launch shape**: matches cc-openclaw.sh lines 275-284. Pane runs
  `claude --mcp-config <file> --add-dir <cwd> --permission-mode bypassPermissions`;
  claude auto-spawns cc_mcp as a stdio subprocess per the mcp-config. See §4.2 A
  for the rendered command. The `--dangerously-load-development-channels` flag
  cc-openclaw uses is NOT needed for ESR — that flag only registers *built-in*
  MCP servers shipped with claude; `--mcp-config` already handles arbitrary
  external servers.

- **`ESR_BOOTSTRAP_PRINCIPAL_ID` purpose** (review feedback #2): fresh-install
  fallback for the "no capabilities.yaml yet" state:
    1. **Boot-time** (`runtime/lib/esr/capabilities/supervisor.ex:37-58`): if
       `capabilities.yaml` is absent AND the env var is set, ESR writes a seed
       file granting that principal wildcard `["*"]`. Lets a brand-new install
       accept admin commands before anyone manually grants capabilities.
    2. **Runtime** (`runtime/lib/esr_web/channel_channel.ex:52, 79`): used as
       the default `principal_id` when a cc_mcp client connects without
       sending `session_register`, or when `tool_invoke` arrives before
       register. Lane B capability checks use this to authorize tool calls.
  
  **For e2e scenario 01**: `common.sh` should export
  `ESR_BOOTSTRAP_PRINCIPAL_ID=ou_admin` *before* `start_esrd` — this already
  matches the `ou_admin` principal seeded by `seed_capabilities`. Without it,
  Lane B rejects cc_mcp's tool_invoke. Adding as T11b.0a pre-check (small
  common.sh export; no new infrastructure).

- **`send_file` paths**: CC passes absolute paths. The adapter-side `uploads_dir` config
  (already in `AdapterConfig`, see `py/tests/adapter_runners/test_feishu_send_file.py:39`)
  is where inbound downloads land — it's not a generic scratch dir. No new
  `ESR_UPLOADS_DIR` env var. Decided: use existing `AdapterConfig.uploads_dir`.

- **`SendInput` as tmux-only debug path**: not in T11b. If a future need arises
  for "admin sends raw keystrokes", add a separate `{:tmux_keys, text}` action;
  don't overload `SendInput`.

- **MCP server discovery**: `workspaces.yaml` already has a `start_cmd` field
  on each workspace (`Esr.Workspaces.Registry.Workspace` struct). T11b sources
  `start_cmd` from the workspace config if non-empty; else falls back to the
  default `claude --mcp-config …` invocation in §4.2 A. One config surface,
  zero new concepts.

- **Dup-join hazard** (added from live 2026-04-24 incident — see
  `docs/notes/mcp-transport-orphan-session-hazard.md`): T11b's
  `EsrWeb.ChannelChannel.join/3` must reject a second join on the same
  `cli:channel/<session_id>` topic. cc-openclaw's channel-server silently
  last-writer-wins on dup registrations, and then detaching one orphan
  suspends the whole actor. Reject explicitly with `{:error, %{reason:
  "already_joined", existing_ws_pid: <pid>}}` so the second client fails
  fast. Adds as work item **T11b.4a** under §5.

## 9a. Remaining Unknowns (minimal, post-review)

- FCP message-tuple arity disambiguation — T11b adds
  `handle_info({:tool_invoke, req_id, tool, args, channel_pid, principal_id}, state)`
  (6-tuple, matching `channel_channel.ex:85`). Existing FCP has `{:reply, _}`
  + `{:reply, _, opts}`. No collision; docstring must call out the exact
  arities.

## 10. Out of Scope

- Voice pipeline (`voice.yaml` agent): unchanged. Voice peers still use `HandlerRouter.call` with voice-specific handlers.
- Scenario 02 (two concurrent users) + scenario 03 (tmux attach/edit): separate e2e fixes after T11b lands.
- CLI command forwarding (`forward`, `spawn_session` in cc-openclaw): out of T11b — those unlock multi-session orchestration, which is PR-10+ material.

---

## 11. Approval Checklist

- [ ] Data flow (§4.1) reviewed for round-trip correctness
- [ ] Work-item ordering (§5) agrees with dependency graph
- [ ] Test plan (§6) covers happy path + at least one regression pin per structural change
- [ ] Risks (§8) acknowledged; any new ones surfaced during review get added
- [ ] Open questions (§9) resolved before starting T11b.1

Once all checked, T11b implementation proceeds under subagent-driven-development (one subagent per work item, two-stage review per task).

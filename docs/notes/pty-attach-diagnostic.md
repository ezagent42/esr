# PTY attach diagnostic procedure

**Purpose**: when an esrd-spawned `claude` session appears unresponsive
(operator types in Feishu, no reply), this procedure walks the
chain end-to-end and isolates which layer broke. Live-debugged
2026-05-02 during PR-24's binary-WS migration.

## Why this doc exists

Pattern-matching on claude TUI output ("smart" auto-fix) is brittle —
every claude version + plugin change can introduce new dialogs. This
procedure captures the **manual diagnostic flow** so the failure mode
is observable, repeatable, and the fix is data-driven instead of
guessed.

## Architecture cheat-sheet

```
飞书 user
  ↓ Lark websocket
feishu_adapter_runner (Python)
  ↓ adapter:feishu/<app_id> Phoenix Channel
EsrWeb.AdapterChannel  → forward
Esr.Peers.FeishuAppAdapter (FAA)
  ↓ SessionRegistry.lookup_by_chat(chat_id, app_id)   [PR-21λ]
  ↓ send(FCP, {:feishu_inbound, ...})
agents.yaml inbound chain:
  FeishuChatProxy → CCProxy → CCProcess → PtyProcess
  ↓ CCProcess invokes cc_adapter_runner Python handler
  ↓ handler returns actions:[{type:send_input, text:"hi"}]
  ↓ CCProcess broadcasts {:notification, envelope}
     on Phoenix.PubSub topic "cli:channel/<sid>"
                        ↓
                cc_mcp (MCP server inside claude)
                        ↓ notifications/claude/channel
                claude sees <channel source="esr-channel"…>hi</channel>
                claude responds via mcp__esr-channel__reply
                        ↓ tool_invoke envelope
                EsrWeb.ChannelChannel  → Registry "thread:<sid>" → FCP
                        ↓ Feishu IM API
                飞书 user sees reply
```

PTY (`Esr.Peers.PtyProcess`) is **only** for operator `/attach`.
Inbound/outbound business traffic flows via cc_mcp's WebSocket on
`cli:channel/<sid>`, **not** via PTY stdin/stdout.

## Per-stage check

### 1. Was the session registered under the right key?

Tail the BEAM stdout log for the `register_session` line (re-add the
diagnostic Logger if it was stripped — see `lib/esr/session_registry.ex`
`handle_call({:register_session, …})`):

```bash
grep "register_session" $ESRD_HOME/<instance>/logs/launchd-stdout.log | tail -5
```

Expected: `key={"oc_b7a242…", "esr_dev_helper"}`. If `app_id` is
`"default"` instead of the real adapter instance id, PR-150's
`app_id` threading regressed.

### 2. Was the inbound `lookup` a hit or miss?

Same log file, look for `FAA.do_handle_upstream_inbound` followed by
either silence (= hit, message routed) or `lookup=:not_found` (= miss,
auto-spawn fallback fires).

### 3. Did claude actually spawn the cc_mcp child?

```bash
claude_pid=$(pgrep -f "claude.*esr-channel" | head -1)
pgrep -P $claude_pid
```

Expected: at least one PID — the `uv run` wrapper that became
`python -m esr_cc_mcp.channel`. If empty, **claude is hung pre-MCP-spawn**
and you go to step 4.

### 4. Is claude hung on a TUI dialog?

The most common case: `--dangerously-load-development-channels` warning.
claude renders ~250 bytes of ANSI escapes (the dialog frame) then waits
for "1\r" confirmation. Without an attached terminal, the dialog never
gets answered.

**Diagnose**: connect with websocat in binary mode and visually inspect
what claude is rendering:

```bash
sid=<your_session_id>
(printf '{"cols":120,"rows":40}\n'; sleep 5) | websocat --binary -E \
    "ws://127.0.0.1:4001/attach_socket/websocket?sid=${sid}" \
    > /tmp/cap.bin

# Decode (ANSI-strip) for human reading
uv run python3 -c "
import re
data = open('/tmp/cap.bin','rb').read()
clean = re.sub(rb'\x1b\[[0-9;?]*[A-Za-z]', b' ', data)
text = re.sub(rb'\s+', b' ', clean).decode('utf-8', errors='replace')
print(text[:4000])
"
```

If you see `WARNING: Loading development channels …` text, that's the
dev-channels dialog. Apply the unblock:

```bash
scripts/cc-bootstrap.sh "${sid}"
```

The script connects to the same attach socket and sends `1\r` as a
binary frame. After this, repeat step 3 — `pgrep -P` should now show
the cc_mcp child.

### 5. Did cc_mcp join the BEAM Phoenix Channel?

```bash
grep "JOINED cli:channel/${sid}" $ESRD_HOME/<instance>/logs/launchd-stdout.log
grep "session_register" $ESRD_HOME/<instance>/logs/launchd-stdout.log | tail -5
```

Expected: a `JOINED cli:channel/<sid>` info line and a `kind =>
session_register` envelope from cc_mcp carrying the workspace + chats
metadata. If missing, cc_mcp boot failed (proxy unreachable, creds
expired, MCP module import error) — `ps eww <cc_mcp_pid>` and
`uv run --project py python -m esr_cc_mcp.channel --help` to debug.

### 6. Did the inbound notification reach claude?

After cc_mcp joins, any buffered `pending_notifications` in cc_process
gets flushed. Look for:

```bash
grep "channel notification dispatched" $ESRD_HOME/<instance>/logs/launchd-stdout.log | tail -5
```

If the dispatched line appeared **before** the JOIN line, the buffer-
flush logic from `cc_process.handle_info({:cc_mcp_ready, _})` worked.
If the dispatched line is **after** JOIN, this is a fresh inbound that
arrived after the session was already healthy — also fine.

### 7. Did claude call the reply tool?

```bash
grep "tool_invoke" $ESRD_HOME/<instance>/logs/launchd-stdout.log | tail -5
```

Expected: an envelope with `kind => "tool_invoke"`, `tool => "reply"`.
If absent, claude received the inbound but chose not to reply (could be
prompt-injection refusal, or claude is still composing).

### 8. Did the reply hit the Feishu API?

```bash
grep "open.feishu.cn:443.*POST.*messages" $ESRD_HOME/<instance>/logs/launchd-stdout.log | tail -3
```

Expected: a `POST /open-apis/im/v1/messages?receive_id_type=chat_id`
HTTP request from the python feishu adapter. The next line should be
the response status (200 = delivered).

## Solidified tools

- `scripts/cc-bootstrap.sh <sid>` — websocat-based one-shot dialog
  unblock. Uses the same WS endpoint xterm.js attaches to.
- `scripts/esr-cc.sh` — already pre-trusts the cwd in `~/.claude.json`
  before exec'ing claude (PR-21µ-fix). Independent fix; doesn't replace
  the dev-channels confirmation step.
- `lib/esr_web/pty_socket.ex` — raw binary WS transport. PTY bytes
  flow through unchanged so xterm.js and websocat both render claude's
  TUI accurately.

## Common failure modes

| Symptom | Likely stage | Fix |
|---|---|---|
| "Hi" gets no reply, claude pid alive, no children | 4 | `cc-bootstrap.sh <sid>` |
| Slash works, reply goes nowhere | 1 | `app_id` not threaded — verify register key |
| Multiple claude processes per chat | 1 | Pre-PR-21λ thread_id-misroute regression |
| xterm.js render is garbled gibberish | n/a | Phoenix.Channel JSON serialization (fixed by PR-24) |
| Plugin reload loop / repeated banner | claude-side | Operator action; not an esrd bug |

## Why the dev-channels dialog is unavoidable

Per `https://code.claude.com/docs/en/channels-reference`, the
`--dangerously-load-development-channels` flag is **required** for any
channel not on Anthropic's allowlist. ESR's `esr-channel` will never
be on that allowlist (private deployment) — so the flag is permanent
and the confirmation dialog is permanent.

The dialog is interactive by design (security gate against drive-by
malicious channels). Skipping it requires either pre-answering it or
using `--print` mode (no TUI, breaks /attach).

`scripts/cc-bootstrap.sh` is the manual workaround. A code-level fix
(one-shot Logger.send_after in PtyProcess.init) is tracked separately
— rejected option (b) "smart text detection" is fragile across claude
versions.

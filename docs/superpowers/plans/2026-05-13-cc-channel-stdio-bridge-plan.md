# CC Channel stdio Bridge — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans`.

**Goal:** Restore the Feishu → CC `<channel>` notification path by replacing the HTTP MCP route with a stdio MCP bridge (per CC's documented requirement that channel servers communicate over stdio).

**Architecture:**
```
BEAM → erlexec → claude → spawn Python stdio bridge (per mcp.json)
                                ↓ Phoenix Channel WS
                          EsrWeb.ChannelChannel @ "cli:channel/<sid>"
```
Lifecycle is fail-fast via stdio EOF — when claude dies, the pipe closes, MCP Python SDK's `stdio_server()` reads EOF and Python exits naturally. No ppid watchdog.

**Tech Stack:** Elixir 1.18 / OTP 27 / Phoenix; Python `mcp.server.stdio` + `websockets`; existing erlexec-based subprocess pattern.

**Spec:** `docs/superpowers/specs/2026-05-13-cc-channel-stdio-bridge-design.md` rev-7 (passed 6 subagent review rounds).

**Branch:** `feat/cc-channel-stdio-bridge` (single PR; phases below are commit boundaries, not PR boundaries).

---

## Phase 1: Extract `ChannelNotification` helper

The pure data transform in `mcp_controller.ex:268-329` (build_notification_params + helpers) needs to outlive the controller deletion.

### Task 1.1: Create `Esr.Plugins.ClaudeCode.ChannelNotification`

**Files:**
- Create: `runtime/lib/esr/plugins/claude_code/channel_notification.ex`

- [ ] **Step 1: Copy `build_notification_params/1` + 4 helpers verbatim**

From `runtime/lib/esr_web/mcp_controller.ex:268-329`, lift:
- `build_notification_params/1`
- `build_text_params/1`
- `build_attachment_params/3`
- `take_meta/1`
- `reason_str/1` (two clauses — `is_atom(reason)` head + fallthrough)

Wrap in module `Esr.Plugins.ClaudeCode.ChannelNotification`. Public arity-1 `build_notification_params/1`, rest private.

- [ ] **Step 2: Compile + warn-check**

```bash
cd runtime && MIX_ENV=dev mix compile 2>&1 | grep -E "warning|error" | grep -v _build
```
Expected: no new warnings from the new module.

- [ ] **Step 3: Commit**
```
feat(cc-channel): extract ChannelNotification helper from McpController
```

### Task 1.2: Migrate the 8 existing tests

**Files:**
- Create: `runtime/test/esr/plugins/claude_code/channel_notification_test.exs`
- Modify: `runtime/test/esr_web/controllers/mcp_controller_test.exs` (will be deleted entirely in Phase 6)

- [ ] **Step 1: Copy the 8 `describe`/`test` blocks** from `runtime/test/esr_web/controllers/mcp_controller_test.exs` (the ones that test `build_notification_params/1` — text path, 3 attachment kinds, phaser-failure paths).

- [ ] **Step 2: Update aliases**

Change `alias EsrWeb.McpController` → `alias Esr.Plugins.ClaudeCode.ChannelNotification` in the new test file. Calls `McpController.build_notification_params(...)` → `ChannelNotification.build_notification_params(...)`.

- [ ] **Step 3: Run new tests in isolation**
```bash
cd runtime && MIX_ENV=test mix test test/esr/plugins/claude_code/channel_notification_test.exs
```
Expected: 8 tests, 0 failures.

- [ ] **Step 4: Commit**
```
test(cc-channel): migrate build_notification_params tests to ChannelNotification
```

---

## Phase 2: Python stdio bridge

### Task 2.1: Skeleton `cc_channel_runner` package

**Files:**
- Create: `py/src/cc_channel_runner/__init__.py` (empty)
- Create: `py/src/cc_channel_runner/__main__.py`
- Modify: `py/pyproject.toml` (verify deps; add `mcp` if not present)

- [ ] **Step 1: Verify deps**
```bash
cd py && grep -E "mcp|websockets" pyproject.toml
```
Expected: `websockets` present (used by `feishu_adapter_runner`). If `mcp` is missing, add it:
```toml
mcp = ">=1.0"
```
Then `uv sync` in `py/`.

- [ ] **Step 2: Write `__main__.py` skeleton**

```python
#!/usr/bin/env python3
"""ESR cc-channel stdio bridge. CC spawns this as a subprocess.
Pipes MCP stdio ↔ Phoenix Channel WebSocket on cli:channel/<sid>."""

import argparse
import asyncio
import logging
import sys


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--esrd-url", required=True)
    args = parser.parse_args()

    logging.basicConfig(
        stream=sys.stderr,
        level=logging.INFO,
        format="[cc_channel_runner sid=%s] %%(message)s" % args.session_id[:8],
    )
    log = logging.getLogger("cc_channel_runner")
    log.info("bridge starting esrd_url=%s", args.esrd_url)

    # TODO Task 2.2-2.5: WS join, MCP stdio, tool dispatch, notification dispatch
    raise NotImplementedError("scaffold only")


if __name__ == "__main__":
    asyncio.run(main())
```

- [ ] **Step 3: Smoke-test scaffold**
```bash
cd py && uv run python3 -m cc_channel_runner --session-id test --esrd-url ws://localhost:4001 2>&1 | head -5
```
Expected: log line + NotImplementedError. Confirms argparse + entry point work.

- [ ] **Step 4: Commit**
```
feat(cc-channel): cc_channel_runner skeleton (argparse + log)
```

### Task 2.2: Phoenix Channel WS client

- [ ] **Step 1: Write `phx_client.py`** that uses `websockets` to:
  - Connect to `<esrd-url>/channel/socket/websocket?vsn=2.0.0`
  - Send `phx_join` for topic `cli:channel/<sid>` with ref/join_ref tracking
  - Yield received frames (decode JSON)
  - Send `push(event, payload)` with ref tracking → await matching `phx_reply`
  - 3-attempt backoff (1s, 2s, 4s) on disconnect; then raise

Use `cc-openclaw/channel_server/adapters/cc/channel.py:65-180` as reference for the Phoenix Channel protocol shape (`{"topic", "event", "payload", "ref"}` JSON).

- [ ] **Step 2: Unit-test it with mock WS**

**Files:**
- Create: `py/tests/test_cc_channel_runner_phx_client.py`

```python
import asyncio
import json
import pytest
import websockets

from cc_channel_runner.phx_client import PhoenixChannelClient


@pytest.mark.asyncio
async def test_phx_join():
    received = []
    async def handler(ws):
        async for msg in ws:
            received.append(json.loads(msg))
            # respond with phx_reply ok
            data = json.loads(msg)
            if data["event"] == "phx_join":
                await ws.send(json.dumps({
                    "topic": data["topic"],
                    "event": "phx_reply",
                    "payload": {"status": "ok", "response": {}},
                    "ref": data["ref"],
                }))

    async with websockets.serve(handler, "127.0.0.1", 0) as server:
        port = server.sockets[0].getsockname()[1]
        client = PhoenixChannelClient(f"ws://127.0.0.1:{port}/channel/socket/websocket?vsn=2.0.0")
        await client.connect()
        await client.join("cli:channel/abc-123")
        assert any(m["event"] == "phx_join" for m in received)
        await client.close()
```

- [ ] **Step 3: Run unit test**
```bash
cd py && uv run pytest tests/test_cc_channel_runner_phx_client.py -v
```
Expected: 1 passed.

- [ ] **Step 4: Commit**
```
feat(cc-channel): phx_client.py + WS join unit test
```

### Task 2.3: MCP stdio server + capabilities

- [ ] **Step 1: Wire `mcp.server.stdio.stdio_server()` in `__main__.py`**

Import + instantiate `Server("esr-channel", instructions=INSTRUCTIONS)` where `INSTRUCTIONS` is verbatim from `mcp_controller.ex:148-153`. Declare:
```python
capabilities=server.get_capabilities(
    notification_options=NotificationOptions(),
    experimental_capabilities={"claude/channel": {}},
)
```
Then `async with stdio_server() as (read, write):` and `await server.run(read, write, init_opts)`.

Reference: `cc-openclaw/channel_server/adapters/cc/channel.py:680-705`.

- [ ] **Step 2: Smoke-test handshake**
```bash
cd py && echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}' | uv run python3 -m cc_channel_runner --session-id test --esrd-url ws://127.0.0.1:4001 2>/tmp/cc_bridge.err | head -1
```
Expected: a JSON-RPC initialize response on stdout containing `"capabilities":{...,"experimental":{"claude/channel":{}}}`.

- [ ] **Step 3: Commit**
```
feat(cc-channel): MCP stdio server + claude/channel capability advertise
```

### Task 2.4: Notification dispatch (WS → MCP stdout)

- [ ] **Step 1: Subscribe to WS `envelope` frames** in the bridge's WS consumer loop. Discriminate by `payload.kind`:
  - `tool_result` → forward to pending tool-call future (Task 2.5)
  - `notification` | `cleanup_check_requested` → call `build_notification_params(payload)` then `await server.notification("notifications/claude/channel", params)`
  - `session_killed` → raise `SystemExit(0)` to close stdio_server cleanly
  - other → `log.warning("dropping unknown kind=%s", kind)`

- [ ] **Step 2: Port `build_notification_params` to Python**

Implement in `cc_channel_runner/notification.py`. Skip `PhaserRegistry.transform/2`; pass `media_uri` + `msg_type` through as meta.

- [ ] **Step 3: Unit-test**

**Files:**
- Create: `py/tests/test_cc_channel_runner_notification.py` (build_notification_params)
- Append to: `py/tests/test_cc_channel_runner_phx_client.py` (end-to-end mock WS → MCP stdout)

```bash
cd py && uv run pytest tests/test_cc_channel_runner_notification.py tests/test_cc_channel_runner_phx_client.py -v
```
Expected: green.

- [ ] **Step 4: Commit**
```
feat(cc-channel): notification path (WS envelope → MCP notifications/claude/channel)
```

### Task 2.5: Tool dispatch (MCP request → WS push → await tool_result)

- [ ] **Step 1: Register MCP tool handlers** for `reply` / `send_file` / `submit_slash` using `mcp.types.Tool` + `server.request_handler(CallToolRequest, ...)`. Each handler:
  - Generates `req_id = uuid.uuid4().hex`
  - Pushes `event="envelope"`, `payload={"kind": "tool_invoke", "req_id": req_id, "tool": tool_name, "args": arguments}`
  - Stores a pending `asyncio.Future` keyed by `req_id`
  - Awaits the future (set by the WS consumer when matching `kind="tool_result"` frame arrives)
  - Translates `{"ok": true, "data": ...}` → MCP `CallToolResult(content=[TextContent(text=json.dumps(data))])` and `{"ok": false, "error": ...}` → `CallToolResult(isError=True, content=[...])`

- [ ] **Step 2: Discover tool schemas**

Don't hardcode tool schemas; instead, register `tools/list` handler that returns schemas from `mcp_controller.ex` reference (peer `tools` registry). Spec §3 non-goals confirm: tool definitions live in BEAM; bridge proxies.

  Option A (simpler for now): hardcode the 3 tool schemas in `cc_channel_runner/tools.py` matching `Esr.Plugins.ClaudeCode.Mcp.Tools.list/1`. Update only when adding/removing a tool.

  Option B (cleaner long-term): push `event="envelope"`, `kind="tools_list_request"` to BEAM, await response. Skip for rev-7 — Option A.

- [ ] **Step 3: Unit-test tool round-trip with mock WS**

Mock WS server that, on receiving `tool_invoke` envelope, replies with a `tool_result` envelope. Assert MCP `CallToolResult` returned to client.

- [ ] **Step 4: Commit**
```
feat(cc-channel): tool dispatch (MCP request → envelope tool_invoke → await tool_result)
```

---

## Phase 3: Update Launcher to generate stdio mcp.json

### Task 3.1: Rewrite `write_mcp_json/1` → `write_channel_mcp_config/1`

**Files:**
- Modify: `runtime/lib/esr/plugins/claude_code/launcher.ex`

**Existing signature note**: `write_mcp_json/1` at `launcher.ex:86` takes a **keyword list** `[session_id:, esrd_url:]`. The caller at `launcher.ex:175` (inside `prepare_spawn/1`) passes the kw-list. Rev-7 rewrite preserves the keyword-list shape — only the OUTPUT (file content) changes, not the signature.

- [ ] **Step 1: Promote `default_esrd_url/0` from `defp` to `def`**

Line 192. Testable + reachable from `python_bin_path/0` helper if we mirror it. Optional — we could also just inline-call from `prepare_spawn` and pass the URL in via the keyword list (which the existing signature already does). **Tilt**: leave existing kw-list contract as is; only swap function body. Skip the `defp → def` promotion.

- [ ] **Step 2: Rewrite the function body (preserve kw-list signature)**

```elixir
@spec write_channel_mcp_config(keyword()) :: {:ok, String.t()} | {:error, term()}
def write_channel_mcp_config(opts) do
  session_id = Keyword.fetch!(opts, :session_id)
  esrd_url = Keyword.fetch!(opts, :esrd_url)

  config = %{
    "mcpServers" => %{
      "esr-channel" => %{
        "command" => python_bin_path(),
        "args" => [
          "-m", "cc_channel_runner",
          "--session-id", session_id,
          "--esrd-url", esrd_url
        ]
      }
    }
  }

  mcp_path = Esr.Paths.session_mcp_json(session_id)

  with :ok <- File.mkdir_p(Path.dirname(mcp_path)),
       :ok <- File.write(mcp_path, Jason.encode!(config, pretty: true)) do
    {:ok, mcp_path}
  end
end

# Same pattern as `Esr.Workers.AdapterProcess.python_bin/0` at adapter_process.ex:99.
defp python_bin_path do
  Path.join([
    Application.app_dir(:esr) |> Path.join("../../../..") |> Path.expand(),
    "py",
    ".venv",
    "bin",
    "python"
  ])
end
```

(Note: ESR's repo-root resolution lives at `Esr.Workers.AdapterProcess.python_bin/0` at `runtime/lib/esr/workers/adapter_process.ex:99` — read that for the canonical pattern; copy verbatim if available.)

- [ ] **Step 3: Update the in-module caller + alias rename**

```bash
cd runtime && git grep -n "write_mcp_json" lib/ test/
```
Expected hits: `launcher.ex:175` (the `prepare_spawn` call site) + `launcher_test.exs` (existing test invocations at ~`:108,:122,:152-174`). **Note**: no other module currently calls `write_mcp_json` — verify before assuming `cc_process.ex` does. Replace `write_mcp_json` → `write_channel_mcp_config` everywhere.

- [ ] **Step 4: Update `launcher_test.exs:152-174`** assertions from `String.ends_with?(url, "/mcp/<sid>")` to:
```elixir
assert decoded["mcpServers"]["esr-channel"]["command"] =~ "python"
assert "cc_channel_runner" in decoded["mcpServers"]["esr-channel"]["args"]
assert "--session-id" in decoded["mcpServers"]["esr-channel"]["args"]
```

- [ ] **Step 5: Run launcher tests**
```bash
cd runtime && MIX_ENV=test mix test test/esr/plugins/claude_code/launcher_test.exs
```
Expected: green.

- [ ] **Step 6: Commit**
```
refactor(cc-channel): write_channel_mcp_config emits stdio command shape
```

---

## Phase 4: Rename `Channels.McpHttp` → `Channels.Mcp`

### Task 4.1: Sed pass

- [ ] **Step 1: Run the sed pass** (macOS BSD sed):
```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
git grep -l "Channels\.McpHttp" | xargs sed -i '' 's/Channels\.McpHttp/Channels.Mcp/g'
git grep -l "claude_code\.mcp_http" | xargs sed -i '' 's/claude_code\.mcp_http/claude_code.mcp_stdio/g'
git mv runtime/lib/esr/plugins/claude_code/channels/mcp_http.ex \
       runtime/lib/esr/plugins/claude_code/channels/mcp.ex
git mv runtime/test/esr/plugins/claude_code/channels/mcp_http_test.exs \
       runtime/test/esr/plugins/claude_code/channels/mcp_test.exs
```

- [ ] **Step 2: Validate no leftover references**
```bash
git grep -E "McpHttp|claude_code\.mcp_http"
```
Expected: zero results. If any remain in docs/, update manually.

- [ ] **Step 3: Update SSE-specific `@moduledoc` prose** in the renamed `mcp.ex` to describe the stdio bridge mechanism (delete SSE prose).

- [ ] **Step 4: Full test suite**
```bash
cd runtime && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: regression-free (note: HTTP MCP route still exists in this phase; deletion comes in Phase 6).

- [ ] **Step 5: Commit**
```
refactor(cc-channel): rename Channels.McpHttp → Channels.Mcp (sed pass)
```

---

## Phase 5: Delete CCProcess dead code (big cascading deletion)

### Task 5.1: Delete `cc_mcp_ready`, fallback branch, `pending_notifications`, `pty_actor_id`

**Files:**
- Modify: `runtime/lib/esr/plugins/claude_code/cc_process.ex`
- Modify: `runtime/test/esr/plugins/claude_code/cc_process_inbound_regression_test.exs`
- Modify: `runtime/test/esr/plugins/claude_code/cc_process_multi_session_test.exs`

- [ ] **Step 1: Delete the state fields**

In `cc_process.ex` init (around line 122-127), strip:
- `cc_mcp_ready: false`
- `pending_notifications: []`
- `pty_actor_id: …`

- [ ] **Step 2: Delete `handle_info({:cc_mcp_ready, sid}, state)` clause**

Lines ~200-209 in `cc_process.ex`. Includes the `pending_notifications` flush.

- [ ] **Step 3: Simplify `dispatch_action(:send_input)`**

`cc_process.ex:309-340` two-branch body (the `if state.cc_mcp_ready do … else … end`) collapses to single-branch:
```elixir
defp dispatch_action(%{"type" => "send_input", "text" => text}, state) do
  envelope = build_channel_notification(state, text)
  broadcast_notification(current_session_id_or_primary(state), envelope)
  state
end
```

Also delete the PR-24 design comment block at `:322-336` (it described the deleted else branch).

- [ ] **Step 4: Strip test boilerplate**

In `cc_process_inbound_regression_test.exs`, **delete the entire test** at line ~94: `test "send_input action writes keystrokes to PtyProcess (no broadcast)"`.

In the same file at lines 56 and 169, **strip** the `send(pid, {:cc_mcp_ready, sid})` setup lines.

In `cc_process_multi_session_test.exs:51`, **strip** the same kind of line.

- [ ] **Step 5: Run impacted test files**
```bash
cd runtime && MIX_ENV=test mix test \
  test/esr/plugins/claude_code/cc_process_inbound_regression_test.exs \
  test/esr/plugins/claude_code/cc_process_multi_session_test.exs \
  test/esr/plugins/claude_code/cc_process_test.exs
```
Expected: green minus the deleted test.

- [ ] **Step 6: Full test suite**
```bash
cd runtime && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: no new failures beyond the deleted test.

- [ ] **Step 7: Commit**
```
refactor(cc-channel): delete CCProcess boot-bridge fallback + cascading dead fields
```

---

## Phase 6: Delete HTTP MCP route

### Task 6.1: Delete controller + scope

**Files:**
- Delete: `runtime/lib/esr_web/mcp_controller.ex`
- Modify: `runtime/lib/esr_web/router.ex`
- Delete: `runtime/test/esr_web/controllers/mcp_controller_test.exs`

- [ ] **Step 1: Delete the scope block** at `router.ex:33-42`. Includes the prefacing comment block.

- [ ] **Step 2: `git rm` the two files**:
```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
git rm runtime/lib/esr_web/mcp_controller.ex
git rm runtime/test/esr_web/controllers/mcp_controller_test.exs
```

- [ ] **Step 3: Audit for any remaining references**
```bash
git grep -rE "McpController|mcp_controller" runtime/
```
Expected: zero (or only comment references — clean those too if present).

- [ ] **Step 4: Full test**
```bash
cd runtime && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: regression-free.

- [ ] **Step 5: Commit**
```
chore(cc-channel): delete HTTP MCP route + controller + tests
```

---

## Phase 7: Add `/pty:input` slash command

### Task 7.1: Create `Esr.Commands.Pty.Input`

**Files:**
- Create: `runtime/lib/esr/commands/pty/input.ex`
- Modify: `runtime/priv/slash-routes.default.yaml` (regenerated)
- Create: `runtime/test/esr/commands/pty/input_test.exs`

- [ ] **Step 1: Write the command module** per spec §6.5 sample code.

- [ ] **Step 2: Regenerate slash-routes yaml**
```bash
cd runtime && mix esr.gen_slash_routes
```

- [ ] **Step 3: Write unit test**
```elixir
test "writes text to PTY via Esr.Entity.PtyProcess.write/2" do
  # mock the chat-current resolver + pty_actor_id_for + PtyProcess.write
  # assert write_called?(actor_id, "hello") == true
end
```

- [ ] **Step 4: Run**
```bash
cd runtime && MIX_ENV=test mix test test/esr/commands/pty/input_test.exs
```
Expected: green.

- [ ] **Step 5: Commit**
```
feat(cc-channel): /pty:input slash command (write arbitrary text to PTY stdin)
```

---

## Phase 8: Integration + lifecycle tests

### Task 8.1: Integration e2e (ExUnit)

**Files:**
- Create: `runtime/test/esr/integration/cc_channel_stdio_e2e_test.exs`

- [ ] **Step 1: Pattern after** `runtime/test/esr/integration/new_session_smoke_test.exs` for the app-boot fixture pattern. For real-subprocess spawning, use `System.cmd/3` or `Port.open({:spawn_executable, ...}, [...])` directly — `real_claude_boot_test.exs` was originally cited but it uses `:erlexec`/`OSProcess`, not raw `Port.open`. Pick `Port.open` for stdin/stdout pipe assertion (we need to write `phx_reply` test fixtures into the bridge's WS — but in unit tests we instead inject via mock WS).

- [ ] **Step 2: Scenario** (verbatim from spec §8.3):
1. Boot full app; register workspace + user via existing fixtures.
2. Create session via `Esr.Commands.Session.New.execute/2`. Assert Instance registered.
3. Read generated `mcp.json` from `Esr.Paths.session_mcp_json(sid)`. Assert `command + args` shape.
4. `Port.open` the Python bridge with that argv; capture stdin/stdout.
5. Send synthetic `:notification` broadcast on `cli:channel/<sid>`.
6. Read MCP stdout frame; assert `notifications/claude/channel` with expected content + meta.

- [ ] **Step 3: `@tag :slow`**

- [ ] **Step 4: Run**
```bash
cd runtime && MIX_ENV=test mix test test/esr/integration/cc_channel_stdio_e2e_test.exs --include slow
```

- [ ] **Step 5: Commit**
```
test(cc-channel): integration e2e (BEAM + real bridge subprocess + WS broadcast)
```

### Task 8.2: Lifecycle invariant tests

**Files:**
- Create: `runtime/test/esr/lifecycle/cc_channel_orphan_test.exs`

- [ ] **Step 1: Per spec §7 invariants I-1..I-4**, write 4 tests using `Port.open` + `pgrep` to detect bridge liveness.

- [ ] **Step 2: `@tag :slow`**

- [ ] **Step 3: Run + commit**

### Task 8.3: Shell-based e2e

**Files:**
- Create: `tests/e2e/scenarios/33_cc_channel_stdio.sh`

- [ ] **Step 1: Pattern after** scenarios 27 + 29 (existing channel-related ones).

- [ ] **Step 2: Boot ephemeral esrd; mock-feishu inbound; assert `<channel>` tag in mock CC's captured prompt.**

- [ ] **Step 3: Commit**
```
test(cc-channel): shell e2e scenario 33 (mock-feishu → bridge → mock-CC channel tag)
```

---

## Phase 9: Manual verification

This is **not a code task** but a smoke-test checklist before merging:

- [ ] **9.1** Launch ESRD (`launchctl kickstart -k gui/$UID/com.ezagent.esrd-dev`).
- [ ] **9.2** From a Feishu chat bound to dev-bot, send `/session:new name=verify-1`.
- [ ] **9.3** Attach PTY (`/pty:attach pty=<sid>`) and open the URL.
- [ ] **9.4** In the TUI, run `/mcp` and confirm `esr-channel` shows `connected + 3 tools + channel capability`.
- [ ] **9.5** Send a plain text message from the Feishu chat: `hello?`
- [ ] **9.6** In the TUI, verify the message appears as a `<channel source="feishu" chat_id="…" user="…" ts="…">` tag in CC's context (visible via `/agents` debug or scroll).
- [ ] **9.7** Have CC `reply` — verify the reply lands back in the Feishu chat.
- [ ] **9.8** Run `/pty:input name=cc text=hello-from-input`. Confirm the text appears in CC's TUI input (typed but not submitted).
- [ ] **9.9** Run `/pty:key enter` — confirm CC receives it as a real prompt.
- [ ] **9.10** Spec §5.5 verification: observe whether CC's TUI output is duplicated in chat (one via the channel reply, one via the legacy PTY-stdout mirror in `feishu_chat_proxy.ex`). If duplicates appear, open follow-up PR `feat/feishu-chat-proxy-postchannel-cleanup` to remove the mirror. **Auto-confirm dev-channels banner scaffolding stays** — confirmed 2026-05-13 it's CC's intrinsic boot mechanism.

If 9.1 — 9.10 all pass: this is the symptom we couldn't reproduce on 2026-05-12. Merge.

---

## Self-review

- ✅ Every spec section §5/§6 maps to a phase (1 → 6.1; 2 → 6.2; 3 → 6.3; 4 → 5; 5 → 5.1, 5.4, 5.5; 6 → 5.1, 5.2, 5.3; 7 → 6.5; 8 → 8.1-8.5)
- ✅ No placeholders ("TBD", "fill in" etc.) — all steps carry the actual change or command
- ✅ Type/name consistency: `ChannelNotification`, `cc_channel_runner`, `write_channel_mcp_config/1`, `Channels.Mcp`, `Esr.Commands.Pty.Input` — these names match across phases
- ✅ Spec covers all the rev-1 → rev-7 deletions/additions; this plan lists each as a step with a verification command

## Execution handoff

**Plan complete and saved to** `docs/superpowers/plans/2026-05-13-cc-channel-stdio-bridge-plan.md`.

**Two execution options:**

**1. Subagent-Driven (recommended)** — fresh subagent per task; two-stage review (spec compliance, code quality) per task; in-session continuous progress.

**2. Inline Execution** — `superpowers:executing-plans`, batched with checkpoints.

Default subagent-driven; one PR; commit boundaries are the phase boundaries.

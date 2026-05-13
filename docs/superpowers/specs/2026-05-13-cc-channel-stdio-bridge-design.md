# CC Channel stdio Bridge — Design (rev-7)

**Status:** Draft rev-7. Six subagent code-reviewer passes.
**Author:** Live debugging 2026-05-12 → 2026-05-13 (Feishu).
**Supersedes:** PR-3.5 (2026-05-05) "HTTP MCP transport" — see §1 background.

**Changelog rev-6 → rev-7:**

Rev-6's aggressive deletion was half-applied; rev-7 closes the cascade:
- §5.1 adds: delete `state.pending_notifications` field (only writer was the deleted handler; dead field).
- §5.1 adds: commit to deleting `state.pty_actor_id` field (verified no external readers — `commands/key.ex`, `feishu_chat_proxy.ex`, `commands/tui.ex`, etc all resolve PTY actor_id independently via `Esr.Uri.Compat.pty_actor_id_for/2`, not from CCProcess state).
- §5.1 adds: strip `send(pid, {:cc_mcp_ready, sid})` test-setup boilerplate from `cc_process_inbound_regression_test.exs:56, 169` and `cc_process_multi_session_test.exs:51`. With the handler deleted those become no-ops; tests still pass (broadcast assertions don't depend on the handler) but the setup misleads readers.
- §5.1 line cite fix: PR-24 comment block ends at `cc_process.ex:335`, not `:339` (`:336-339` is the fallback body, not the comment).
- §5.4 / §5.5: noted that `Channels.Mcp` (renamed from `McpHttp`) keeps its own `cc_mcp_ready` subscriber + listener fanout intact — the producer at `channel_channel.ex:70-74` survives, so the `:ready` topic AgentDefBuilder consumer is unaffected. Decoupled from CCProcess's deletion.

**Changelog rev-5 → rev-6:**

Per operator note 2026-05-13: review opinions advocating preservation
of code because regression tests exist are not automatically authoritative
— outdated tests testing dead-code paths should themselves be deleted.
Reapplying that lens to rev-5's §5.4 "NOT removed":

- **`CCProcess.cc_mcp_ready` field + handler + two-branch `dispatch_action(:send_input)` body** — moved from §5.4 (preserve) to §5.1 (delete). With the stdio bridge always firing `cc_mcp_ready` near-instantly at session boot (bridge connects via WS during CC startup, server-side `channel_channel.ex:70-74` broadcasts on join), the "not-ready" branch is unreachable in production. PR-24's deliberate choice of PTY-direct stdin over buffer-and-flush was correct given the absence of a working channel; rev-6 makes the channel work, so the fallback no longer earns its keep.
- **`cc_process_inbound_regression_test.exs` "send_input action writes keystrokes to PtyProcess (no broadcast)" test (file line ~94)** — deleted. It asserts the fallback path's specific behavior; with the fallback gone, the test is asserting the absence of dead code. Other tests in the same file (testing the broadcast path) stay.
- **PR-24 design comment block at `cc_process.ex:322-339`** — deleted along with the fallback branch.
- **`feishu_chat_proxy.ex` `boot_mode` / `pty_buffer` / `pty_flush_timer` / `dev_channels_confirmed`** — **still preserved** for rev-6, but moved from §5.4 to a new §5.5 "deferred deletion candidates" with explicit empirical-verification trigger: if the post-cutover smoke test shows CC doesn't render the dev-channels confirmation dialog under stdio MCP (e.g. because being a recognized channel exempts it from the warning, or the dialog still fires but bridge can dispatch the "1" via an MCP tool), delete in a follow-up PR. Don't delete blind today.

**Changelog rev-4 → rev-5:**
- §6.2 step 5 fabrication fix: `Esr.LifecycleObserver` corrected to `Esr.Session.LifecycleObserver` (real path `runtime/lib/esr/session/lifecycle_observer.ex`). Also acknowledged `session_killed` notification has no current producer in repo — flagged as future producer, lifecycle TBD. Today's only `:notification` broadcast that the bridge will see is `cleanup_check_requested` from `branch_end.ex:252`.
- §6.2 step 5 envelope-kind discrimination rewritten as **whitelist** (known kinds `"notification"`, `"session_killed"`, `"cleanup_check_requested"` forward to MCP; unknown drop with log) rather than blacklist-on-`tool_result`. Robust against future kind additions.
- §6.1 line cite corrected: `mcp_controller.ex:268-329` (def starts at :269; range covers the helpers). Rev-4's `:248-329` was 20 lines low.

**Changelog rev-3 → rev-4:**
- §5.3 fabrication fix: `launcher.ex` + `launcher_test.exs` don't carry `McpController` references — removed from list. Added the real reference at `cc_process.ex:489` (comment `# Task 2.4: pass msg_type + media_uri through so mcp_controller's`).
- §6.2 step 5 protocol-form regression fix: bridge receives `envelope` WS frames pushed by server via `channel_channel.ex:164 push(socket, "envelope", payload)`. Removed the misleading `:notification` PubSub tuple notation. Bridge consumes WS frames, not Erlang tuples.
- §6.2 step 4 wording fix: tool_result arrives as another `envelope` WS frame (`kind: "tool_result"`, `req_id`, plus server merges `:tool_result` result map into the envelope at `channel_channel.ex:168-176`). Bridge correlates by `req_id`.
- §6.2 step 2 line cite corrected: `channel_channel.ex:17` (the `join("cli:channel/" <> session_id, …)` clause), not :35.
- §6.5 line cite corrected: `tui.ex:53` (the `pty_actor_id_for(sid, name)` call), not :55.
- §5.2 header counts corrected to match actual list lengths: "Source files (4)", "Test files (13)".

**Changelog rev-2 → rev-3:**
- §5 cross-ref scope corrected from "14 sites" to **~22 src/test files + 8 docs** (verified by `grep -r`).
- §6.5 fabricated `primary_pty_actor_uuid/1` removed; replaced with the **required `name=` arg pattern** (mirrors `/claude_code:tui` + `/pty:attach`). No invented helpers.
- §6.2 fixed protocol form: bridge pushes `event: "envelope"` with `payload: %{"kind" => "tool_invoke", ...}` matching the actual `EsrWeb.ChannelChannel.handle_in("envelope", %{"kind" => "tool_invoke"} = payload, _)` at `channel_channel.ex:115`.
- §6.4 corrected: `cc_mcp_ready` broadcast **already exists** at `channel_channel.ex:70-74` (PR-9 T12-comms-3c). rev-3 verifies the producer doesn't need re-adding; only the SSE-side producer in `mcp_controller.ex:handle_sse` is deleted.
- §6.2 Python `build_notification_params` re-implementation explicitly **skips PhaserRegistry attachment path resolution**; bridge passes `media_uri` through to CC as a meta attribute. CC-side prompt rendering decides whether to resolve.
- §8.4 scenario file numbered `33_cc_channel_stdio.sh` (32 is occupied).
- Verified `Esr.Commands.Session.New.execute/2` exists at `new.ex:113` (with arity-1 delegating at :110).

## 1. Background

PR-3.5 (`docs/superpowers/specs/2026-05-05-pr-3-5-http-mcp-transport.md`)
replaced the per-session Python stdio MCP bridge with a Phoenix HTTP
route at `/mcp/:session_id`. Rationale: one Elixir endpoint replaces
N Python subprocesses.

Live testing 2026-05-13 surfaced the regression: **Claude Code's
`--channels` / `--dangerously-load-development-channels` flag only
registers stdio-transport MCP servers as channels.** Quoting the
official docs (https://code.claude.com/docs/en/channels-reference):

> Your server needs to:
> 1. Declare the `claude/channel` capability so Claude Code registers a notification listener
> 2. Emit `notifications/claude/channel` events when something happens
> 3. **Connect over stdio transport (Claude Code spawns your server as a subprocess)**

Our HTTP MCP server registered correctly for **tool** discovery (`/mcp`
shows 3 tools connected + authenticated) but the
`--dangerously-load-development-channels server:esr-channel`
registration step failed with the banner `server:esr-channel · no
MCP server configured with that name`. CC's channel registration
iterates stdio-loaded MCP servers only; HTTP MCP servers are invisible
to it. The SSE path
(`mcp_controller.ex:handle_sse` broadcasting `notifications/claude/channel`)
never activates because CC never opens the SSE GET stream.

## 2. Goals

1. **Restore the channel notification path** so inbound Feishu text
   arrives in CC's context as `<channel source="feishu" chat_id="…"
   user="…" ts="…">` tags with full meta.
2. **Eliminate the never-used HTTP MCP route and its dead-code
   contract surface** so future debugging isn't misled by parallel
   transports.
3. **Add `/pty:input`** as an explicit operator-driven path to write
   arbitrary text into PTY stdin. Additive — does not replace the
   `CCProcess` boot-bridge fallback.

## 3. Non-goals

- **Tool dispatch transport change.** CC discovers tools (`reply`,
  `send_file`, `submit_slash`) via the same stdio MCP server; no
  separate HTTP transport for tools.
- **Revival of pre-PR-3.5 `adapters/cc_mcp/`.** That bridge had its
  own complexity (`uv run` wrapping, pidfile). rev-3 ships a fresh
  minimal bridge invoked via the `AdapterProcess` pattern (direct
  python, no uv wrapper, observable pid).
- **Channel protocol extensions.** Implement the documented MCP
  channel protocol verbatim — `claude/channel` capability +
  `notifications/claude/channel` method.
- **Preserve `cc_mcp_ready` field, the PR-24 boot-bridge fallback,
  or `cc_process_inbound_regression_test.exs:94`.** All three are
  dead code once the stdio bridge makes channel notification the
  unambiguous primary path. The regression test asserts a path that
  rev-6 deletes; preserving it because the test exists would be
  circular reasoning. Delete the test alongside the code it covers.

## 4. Architecture

```
BEAM (Elixir, OTP supervisor tree)
  ↓ :erlexec port (kills child on BEAM exit)
PtyProcess (one per session)
  ↓ :erlexec :pty wrapper — claude runs in this PTY
claude (CC binary)
  ↓ subprocess via mcp.json command + args (per CC docs)
Python stdio bridge (py/src/cc_channel_runner/__main__.py)
  ↓ Phoenix Channel WebSocket
EsrWeb.ChannelChannel @ "cli:channel/<session_id>"
  ↓
BEAM Phoenix endpoint
```

**Bridge lifecycle (fail-fast via stdio EOF):**

The Python bridge uses `mcp.server.stdio.stdio_server()`, which
blocks on stdin reads. When claude dies (BEAM kill, crash, exit),
the stdio pipe closes, the asyncio loop reads EOF, and Python exits
naturally. This is the MCP Python SDK's designed lifecycle.

Evidence: cc-openclaw's
`/Users/h2oslabs/cc-openclaw/channel_server/adapters/cc/channel.py`
uses the same pattern in production without a ppid watchdog and
without observed orphaning.

The bridge does **not** inherit claude's PTY as a controlling
terminal — claude passes stdin/stdout to its MCP subprocesses as
pipes. PTY SIGHUP propagation is not a secondary safety net.
**Only stdio EOF matters; it is sufficient.**

## 5. Removal list

### 5.1 Primary targets

| Target | Action |
|---|---|
| `runtime/lib/esr_web/mcp_controller.ex` | **Delete** after extracting `build_notification_params/1` (see §6.1). |
| `runtime/lib/esr_web/router.ex` lines 33-42 (`scope "/mcp/:session_id"` block) | Delete the scope + its comment. |
| `runtime/test/esr_web/controllers/mcp_controller_test.exs` | Migrate the 8 `build_notification_params/1` test cases to new file `runtime/test/esr/plugins/claude_code/channel_notification_test.exs`. Then delete the original. |
| `Esr.Plugins.ClaudeCode.Channels.McpHttp` module | **Rename** to `Esr.Plugins.ClaudeCode.Channels.Mcp`. Files `mcp_http.ex` → `mcp.ex`, `mcp_http_test.exs` → `mcp_test.exs`. Behaviour callbacks identical; SSE-specific moduledoc prose updated. |
| `Esr.Plugins.ClaudeCode.CCProcess.cc_mcp_ready` field | **Delete** field from state, init default removed. With stdio bridge in §6.2, the broadcast at `channel_channel.ex:70-74` fires near-instantly at session boot — the not-ready window is sub-second and not worth a state-machine branch. |
| `cc_process.ex` `handle_info({:cc_mcp_ready, …}, state)` clause | **Delete**. No state to flip. |
| `cc_process.ex:309-340` `dispatch_action(%{"type" => "send_input", ...}, state)` two-branch body | **Replace** with single-branch body that always calls `broadcast_notification(current_session_id_or_primary(state), build_channel_notification(state, text))`. The pre-PR-3.5 PTY-stdin fallback is dropped. |
| `cc_process.ex:322-336` PR-24 design-rationale comment block | **Delete** along with the fallback it describes. |
| `cc_process_inbound_regression_test.exs` "send_input action writes keystrokes to PtyProcess (no broadcast)" test (line ~94) | **Delete** that single test. Other tests in the file (broadcast path, multi-session routing) remain — but strip their `send(pid, {:cc_mcp_ready, sid})` setup lines (see next row). |
| Test-setup `send(pid, {:cc_mcp_ready, sid})` boilerplate in `cc_process_inbound_regression_test.exs:56, 169` + `cc_process_multi_session_test.exs:51` | **Strip** the three send/2 lines. Without the `handle_info({:cc_mcp_ready, …})` clause they become no-ops; the broadcast-path assertions don't depend on them so tests still pass — removing keeps the setup honest. |
| `cc_process.ex` `state.pty_actor_id` field | **Delete** from state struct. Verified no external readers: `commands/key.ex`, `feishu_chat_proxy.ex`, `commands/tui.ex`, `commands/pty/{list,attach,input}.ex`, `uri/compat.ex`, `instance_registry.ex` all resolve PTY actor_id independently via `Esr.Uri.Compat.pty_actor_id_for/2` — they never read CCProcess's state. The only writer/reader was the (deleted) fallback branch. |
| `cc_process.ex` `state.pending_notifications` field | **Delete** from state struct (init at line 127, reader+writer at the `handle_info({:cc_mcp_ready, …})` clause lines 200-209 which this PR also deletes — so the field deletion presupposes the handler deletion in the same PR; both go together). Pre-PR-24 the field buffered notifications during the not-ready window; PR-24 replaced that with PTY-stdin writes; rev-7 deletes both mechanisms. |

### 5.2 Full cross-reference list (verified by `grep -rln -E "McpHttp\|claude_code\.mcp_http"`)

**Source files (4):**
- `runtime/lib/esr/plugins/stub_agent/channels/noop.ex` — `@moduledoc` prose
- `runtime/lib/esr/plugins/feishu/channels/chat_proxy.ex` — `@moduledoc` prose
- `runtime/lib/esr/plugins/claude_code/manifest.yaml` — declares `kind: claude_code.mcp_http`
- `runtime/lib/esr/bundles/feishu-cc/template.yaml` — references `kind: claude_code.mcp_http`

**Test files (13):**
- `runtime/test/esr/plugins/claude_code/channels/mcp_http_test.exs` — rename + assertions
- `runtime/test/esr/integration/new_session_smoke_test.exs`
- `runtime/test/esr/integration/feishu_slash_new_session_test.exs`
- `runtime/test/esr/session_template/parser_test.exs`
- `runtime/test/esr/session_template/registry_test.exs`
- `runtime/test/esr/session_template/agent_def_builder_test.exs`
- `runtime/test/esr/bundle/loader_test.exs`
- `runtime/test/esr/bundles/feishu_cc_test.exs`
- `runtime/test/esr/commands/plugin/enable_test.exs`
- `runtime/test/esr/commands/plugin/install_test.exs`
- `runtime/test/esr/commands/session/new_test.exs`
- `runtime/test/esr/resource/capability_phase6_snapshot_test.exs`
- `runtime/test/mix/tasks/esr_gen_bundle_docs_test.exs`

**E2E scenarios (2):**
- `tests/e2e/scenarios/26_operator_template_override.sh`
- `tests/e2e/scenarios/29_external_bundle_install.sh`

**Docs (8, lower-urgency):**
- `docs/grammar/templates.md`
- `docs/futures/todo.md`
- `docs/superpowers/specs/2026-05-10-session-template-and-channel.md` + zh_cn
- `docs/superpowers/plans/2026-05-10-session-template-and-channel-plan.md` + zh_cn
- `docs/superpowers/specs/2026-05-11-default-agent-and-agent-driven-flow-design.md` + zh_cn
- `docs/manual-checks/2026-05-06-bootstrap-flow-audit.md` + zh_cn (touches `McpController`)
- `docs/notes/2026-05-05-cli-channel-migration.md`

Total: **~22 src/test/scenario + 8 docs** = ~30 files touched by the rename + delete pass.

### 5.3 `McpController` cross-references (verified by `grep -niE "mcpcontroller|mcp_controller"`)

Beyond the controller file + router scope, references appear in:
- `runtime/lib/esr/plugins/claude_code/manifest.yaml` — comment prose
- `runtime/lib/esr/plugins/claude_code/channels/mcp_http.ex` — `@moduledoc` cites `EsrWeb.McpController`
- `runtime/lib/esr/plugins/claude_code/cc_process.ex:489` — comment (`# Task 2.4: pass msg_type + media_uri through so mcp_controller's`)
- `runtime/test/esr/worker_supervisor_test.exs` — comment
- `runtime/test/esr/resource/sidecar/registry_test.exs` — comment

All `@moduledoc` / comment targets — the rename + delete pass covers
them as moduledoc rewrites; no protocol-level dependency. Note:
launcher.ex / launcher_test.exs were incorrectly flagged in rev-3
— verified `grep` returns zero `McpController` references in either.
The launcher tests do need updating per §8.1 because they assert on
the URL shape generated by `write_mcp_json/1`, not because they cite
the controller module.

### 5.4 NOT removed

- `feishu_chat_proxy.ex` PubSub subscriptions to `pty:<actor_id>` +
  `cc_mcp_ready/<sid>` + `pty_attach/<sid>`. All three still serve
  legitimate purposes outside the deleted fallback (browser /attach
  re-wiring, PTY stdout mirroring to chat during dev-channels dialog
  pre-rev-6 — see §5.5 below for the contingent deletion).

### 5.5 Confirmed kept: dev-channels auto-confirm; deferred: PTY-stdout mirror

Operator confirmation 2026-05-13: the
`--dangerously-load-development-channels` warning banner is **CC's
intrinsic boot mechanism**, fires regardless of transport. So:

- **Kept (no deletion plan)**: `feishu_chat_proxy.ex` `boot_mode` /
  `dev_channels_confirmed` state fields + `maybe_confirm_dev_channels/1`
  auto-type-"1\r" logic. These dismiss the banner; they're always
  needed.

- **Deferred deletion candidate**: `pty_buffer` / `pty_flush_timer` +
  the PTY-stdout-to-chat mirror loop. Today this mirrors CC's TUI
  output to chat during the boot bridge window (pre-channel ready).
  Once the bridge is in and channel notification delivers CC output
  via `<channel>` tag replies cleanly, the mirror may become
  redundant — or worse, produce double-posts.

  **Verification trigger**: after rev-7 cutover, smoke-test the first
  real Feishu /session:new. If CC's TUI output is duplicated in chat
  (one from the channel reply, one from the PTY mirror), delete the
  mirror in a follow-up PR (`feat/feishu-chat-proxy-postchannel-cleanup`).
  If mirror is the only channel for some specific message types,
  reduce its scope rather than delete.

## 6. Addition list

### 6.1 Extracted helper: `Esr.Plugins.ClaudeCode.ChannelNotification`

New module at `runtime/lib/esr/plugins/claude_code/channel_notification.ex`.

Lifts `build_notification_params/1` + `build_text_params/1` +
`build_attachment_params/3` + `take_meta/1` + `reason_str/1`
verbatim from `mcp_controller.ex:268-329` (function definitions
begin at line 269; helpers follow). Pure data transform; no state,
no controller dependency.

Public API:
```elixir
@spec build_notification_params(map()) :: %{String.t() => term()}
def build_notification_params(payload), do: ...
```

8 unit tests migrate from `mcp_controller_test.exs` to
`channel_notification_test.exs`. Behavior unchanged.

Elixir-side consumers (any future callers that need the
notification-shape transform without going through MCP): direct
call.

Python bridge: **reimplements the same logic in Python**, with one
deliberate simplification — **skips PhaserRegistry attachment-path
resolution**. The bridge passes `media_uri` and `msg_type` through to
CC as meta attributes; CC-side prompt rendering / agent skill code
decides whether to resolve the URI. Rationale: `PhaserRegistry` is
an Elixir-only resource registry; calling back to BEAM from the
bridge for each attachment defeats the "thin proxy" design. Loses
nothing functional — CC already handles unresolved media URIs.

### 6.2 Python stdio bridge

Module: `py/src/cc_channel_runner/` (parallel to
`py/src/feishu_adapter_runner/`).

Entry point: `python -m cc_channel_runner`.

Argv:
- `--session-id <uuid>`: required
- `--esrd-url <ws-url>`: required (e.g. `ws://127.0.0.1:4001`)

Dependencies (verify in `py/pyproject.toml`): `mcp` (MCP Python SDK)
and `websockets`. The latter is already present via feishu_adapter_runner.

Responsibilities:

1. Open Phoenix Channel WebSocket at
   `<esrd-url>/channel/socket/websocket?vsn=2.0.0`.
2. `phx_join` topic `cli:channel/<sid>` (matches existing
   `def join("cli:channel/" <> session_id, _payload, socket)` at
   `channel_channel.ex:17` — slash separator, not colon).
3. Construct MCP stdio server with:
   - `name`: `esr-channel`
   - `capabilities.experimental['claude/channel'] = {}`
   - `capabilities.tools = {}`
   - `instructions`: verbatim copy of `mcp_controller.ex:148-153`.
4. **Tool dispatch path**: register MCP handlers for `reply`,
   `send_file`, `submit_slash`. Each handler:
   - Generates a `req_id` (ULID).
   - Pushes a Phoenix Channel frame with `event: "envelope"` and
     `payload: %{"kind" => "tool_invoke", "req_id" => req_id, "tool" => tool, "args" => args}`.
     Matches `channel_channel.ex:115` `handle_in("envelope", %{"kind" => "tool_invoke"} = payload, socket)`.
   - Awaits a server-pushed `envelope` WS frame with `payload.kind ==
     "tool_result"` and matching `req_id`. Server-side production: the
     receiving entity peer sends `{:tool_result, req_id, result}` to
     the socket pid, `channel_channel.ex:168-176` receives it via
     `handle_info({:tool_result, ...})` and pushes `envelope` with
     `Map.merge(result, %{"kind" => "tool_result", "req_id" => req_id})`.
   - Translates the result payload's `ok: true | false` shape into the
     MCP tool result (`{content: [...]}` or `{isError: true, content: [...]}`).
5. **Notification path**: when the Phoenix Channel pid receives
   `{:notification, payload}` via auto-subscribed PubSub (per the
   moduledoc-style comment at `channel_channel.ex:160-162`), the
   server pushes `envelope` to the socket at `channel_channel.ex:163-166`
   (`push(socket, "envelope", payload)` — payload passed through
   un-wrapped). The bridge receives these `envelope` WS frames and
   dispatches by `payload.kind`:

   | `payload.kind` value | Action |
   |---|---|
   | `"tool_result"` | Correlate by `req_id` to a pending tool call (§step 4). |
   | `"notification"` | Forward as MCP `notifications/claude/channel` (the inbound text path producer at `cc_process.ex:457` + `entity/server.ex:610`). |
   | `"cleanup_check_requested"` | Forward as MCP notification. Producer: `Esr.Commands.Session.BranchEnd` at `runtime/lib/esr/commands/session/branch_end.ex:252`. |
   | `"session_killed"` | Bridge exits (closes stdio_server context, CC sees EOF). **No producer in repo today** — flagged for future `Esr.Session.LifecycleObserver` (`runtime/lib/esr/session/lifecycle_observer.ex`) integration. Bridge handles defensively. |
   | (any other `kind`) | Log warning and drop. Whitelist discipline — avoids forwarding malformed payloads to MCP. |

   For each forwarded frame the bridge calls its Python
   `build_notification_params(payload)` (re-implementation per §6.1)
   and writes MCP frame
   `{"method": "notifications/claude/channel", "params": {...}}`
   to stdout via `mcp.notification()`.
6. On `:session_killed` notification: bridge closes MCP server
   cleanly (`stdio_server` exits), CC sees stdio EOF.
7. WS disconnect handling: retry up to 3 times with backoff
   (1s/2s/4s). All-failed → exit; CC sees MCP failed.

Invocation pattern matches `Esr.Workers.AdapterProcess` (direct
python, bypass uv wrapper to keep pid observable):
```
<repo>/py/.venv/bin/python -m cc_channel_runner \
  --session-id <sid> \
  --esrd-url ws://<host>:<port>
```

### 6.3 `Esr.Plugins.ClaudeCode.Launcher.write_mcp_json/1` rewrite

`launcher.ex:69-116` currently writes:

```json
{
  "mcpServers": {
    "esr-channel": {
      "type": "http",
      "url": "http://<host>:<port>/mcp/<sid>"
    }
  }
}
```

After rev-3:

```json
{
  "mcpServers": {
    "esr-channel": {
      "command": "/abs/path/to/py/.venv/bin/python",
      "args": [
        "-m", "cc_channel_runner",
        "--session-id", "<sid>",
        "--esrd-url", "ws://<host>:<port>"
      ]
    }
  }
}
```

Implementation:
- `default_esrd_url/0` at `launcher.ex:192` is currently `defp`.
  **Promote to `def`** so the new helper that builds the bridge argv
  can use it cleanly and to keep the function unit-testable.
- Rename function `write_mcp_json/1` → `write_channel_mcp_config/1`
  (reflects the narrowed purpose).
- `python_bin_path/0` helper resolves `<repo>/py/.venv/bin/python`
  (same pattern as `Esr.Workers.AdapterProcess.python_bin/0`).
- Update launcher unit tests `launcher_test.exs:152-174` to assert
  on `command + args` shape instead of `type + url`.

### 6.4 `cc_mcp_ready` broadcast — already wired, no spec change

`EsrWeb.ChannelChannel.join/3` at `channel_channel.ex:70-74` already
broadcasts:
```elixir
Phoenix.PubSub.broadcast(
  EsrWeb.PubSub,
  "cc_mcp_ready/" <> session_id,
  {:cc_mcp_ready, session_id}
)
```

After deleting `mcp_controller.ex:handle_sse`, this WS-join path
becomes the **only** producer of the broadcast — no spec-required
code change here. The `Channels.Mcp` GenServer (renamed from
`McpHttp` per §5) keeps its subscription unchanged.

Verification: the bridge's `phx_join` to `cli:channel/<sid>` triggers
`channel_channel.ex:join/3` once (per WS join), which fires the
broadcast once. The `Channels.Mcp` GenServer's `handle_info({:cc_mcp_ready, sid}, ...)`
fans out to listeners (today: `AgentDefBuilder` via `:ready` topic).
End-to-end semantics identical to pre-rev-3.

### 6.5 `/pty:input` slash command

File: `runtime/lib/esr/commands/pty/input.ex`.

Per `Esr.Commands.Meta` DSL (task #466 made `slash-routes.default.yaml`
derived; new commands declare via DSL, `mix esr.gen_slash_routes`
regenerates the yaml — not hand-edited).

```elixir
defmodule Esr.Commands.Pty.Input do
  use Esr.Commands.Meta

  command :pty_input do
    slash "/pty:input"
    category "PTY"
    description "把任意文本写入指定 agent 的 PTY stdin"
    permission nil
    requires_user_binding true
    requires_workspace_binding false

    arg :name, required: true, doc: "agent name (resolved to PTY actor via session)"
    arg :text, required: true, doc: "free-form text written to PTY stdin literally"

    error :no_session_target,
          "no chat-current session; bind via /session:bind-chat first"
    error :not_found,
          "no agent '%{name}' in chat-current session"
    error :invalid_args, "/pty:input requires name=<agent> and text=<...>"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Session.ChatRouting.Registry, as: ChatRouting

  def execute(%{
        "submitted_by" => _,
        "args" => %{"chat_id" => chat_id, "app_id" => app_id,
                    "name" => name, "text" => text}
      })
      when is_binary(text) and text != "" and is_binary(name) and name != "" do
    with {:ok, sid} <- ChatRouting.current_session(chat_id, app_id),
         {:ok, pty_actor_id} <- Esr.Uri.Compat.pty_actor_id_for(sid, name) do
      :ok = Esr.Entity.PtyProcess.write(pty_actor_id, text)
      {:ok, %{"text" => "🎹 wrote #{byte_size(text)} byte(s) to PTY"}}
    else
      :not_found ->
        Render.error(command_meta(), :not_found, %{name: name})
    end
  end

  def execute(_), do: Render.error(command_meta(), :invalid_args)
end
```

The `name=` arg pattern mirrors `/claude_code:tui` (which uses the
same `Esr.Uri.Compat.pty_actor_id_for(sid, name)` signature at
`runtime/lib/esr/plugins/claude_code/commands/tui.ex:53`). No new
URI/Compat helper added.

Distinction from `/pty:key`:

| | `/pty:key` | `/pty:input` |
|---|---|---|
| Purpose | special non-printable keys (arrows, enter, esc, tab, c-X, f-keys) | arbitrary printable text |
| Escape encoding | named tokens (`enter`, `esc`, `c-x`) translated to byte sequences | text written literally; no escape expansion |
| Trailing `\r` | applicable keys carry their own (e.g. `enter` = `\r`) | **never** — caller follows with `/pty:key enter` if desired |
| Operator UX | "press this key" | "type this text" |

After implementation, run `mix esr.gen_slash_routes` to regenerate
`priv/slash-routes.default.yaml` (per Phase 4 derive invariant,
task #466).

## 7. Process lifecycle invariants

| ID | Invariant | Test fixture |
|---|---|---|
| I-1 | BEAM hard-killed (`launchctl bootout`) → every active session's bridge exits within **5s** | `cc_channel_orphan_test.exs` (§8.3) |
| I-2 | Single session ends (`/session:end name=<…>`) → that session's bridge exits within 5s | same |
| I-3 | CC process killed (SIGKILL on claude pid) → bridge exits within 5s via stdio EOF | same |
| I-4 | BEAM-down while bridge alive → bridge retries 3× with backoff, then exits if no reconnect succeeds | Python unit test (`py/tests/test_cc_channel_runner_ws.py`) |

5s bound is conservative (rev-1's 2s was tight given erlexec's
default kill timeout + WS backoff cycles).

## 8. Testing strategy

### 8.1 Unit tests (Elixir)

**Updated:**
- `runtime/test/esr/plugins/claude_code/launcher_test.exs:152-174` —
  rewrite existing `String.ends_with?(url, "/mcp/<sid>")` assertions
  to assert `command =~ "python"` and `"-m" in args` and
  `"cc_channel_runner" in args`.

**New:**
- `runtime/test/esr/plugins/claude_code/channel_notification_test.exs` —
  8 cases migrated from `mcp_controller_test.exs` covering
  `build_notification_params/1` (text + 3 attachment kinds +
  phaser-failure paths).

### 8.2 Python unit tests

**New:** `py/tests/test_cc_channel_runner_ws.py` (pytest):
- Mock WS server, assert bridge `phx_join`s the right topic.
- Mock notification → assert MCP stdout frame shape.
- Mock tool call → assert Phoenix push event=`envelope` + kind=`tool_invoke` + req_id.
- Stdin EOF → bridge exits within 5s.

### 8.3 Integration tests (`runtime/test/esr/integration/`)

**New:** `runtime/test/esr/integration/cc_channel_stdio_e2e_test.exs`.

Patterns from existing `new_session_smoke_test.exs` and
`real_claude_boot_test.exs` (the latter shows `Port.open` of an
actual subprocess from ExUnit).

Scenario:
1. `setup` starts full app supervisor.
2. Registers workspace + user via existing fixture helpers.
3. Spawn a session via `Esr.Commands.Session.New.execute/2` (arity-2
   verified at `new.ex:113`). Assert Instance registered (per Bug
   C-new fix already landed).
4. Read the generated `mcp.json` at `Esr.Paths.session_mcp_json(sid)`.
   Assert it has `command + args` shape.
5. `Port.open` the Python bridge as a subprocess with the
   captured argv; capture stdin/stdout pipes.
6. Send a synthetic `:notification` broadcast on
   `cli:channel/<sid>` via test fixture.
7. Read MCP stdout frame; assert it contains `notifications/claude/channel`
   with the expected `content` + `meta`.
8. `Port.close/1` to clean up.

`@tag :slow` (depends on Python venv being available in the runner;
shared with `real_claude_boot_test`).

### 8.4 Shell-based e2e (`tests/e2e/scenarios/`)

**New:** `tests/e2e/scenarios/33_cc_channel_stdio.sh` (next free
number after `32_uri_identity_cli_uuid_form.sh`).

Boots an ephemeral esrd, sends a real Lark inbound via the
mock-feishu helper present in the existing scenario suite, asserts
the channel tag appears in mock CC's captured prompt context.
Pattern follows scenarios 27 + 29 (the existing channel-related ones).

### 8.5 Lifecycle invariant tests

**New:** `runtime/test/esr/lifecycle/cc_channel_orphan_test.exs`.

Spawns bridge subprocesses, exercises the 4 kill scenarios in §7
(BEAM SIGKILL / /session:end / claude SIGKILL / BEAM-down). Uses
`pgrep -f "cc_channel_runner --session-id <sid>"` to detect liveness.
`@tag :slow`.

## 9. Migration notes

### 9.1 No data migration

Sessions created before this change have `mcp.json` files with
`type: http` shape. A session restart regenerates them. Operator
action: `/session:end` + `/session:new`, OR kill esrd and restart.

### 9.2 cc-openclaw reference

`/Users/h2oslabs/cc-openclaw/channel_server/adapters/cc/channel.py`
runs the same pattern in production. Use as reference for
`stdio_server()` lifecycle + tool-handler registration.

### 9.3 No feature flag

Hard cutover. No realistic gradient — HTTP MCP path is broken for
channels, stdio bridge fixes it.

### 9.4 `--dangerously-load-development-channels server:esr-channel` retained

Per CC docs §research-preview, custom channels need the dev flag
until allowlisted. `launcher.ex:build_cmd/4` already passes it —
**keep**.

### 9.5 Rename mechanics (sed pass on macOS)

```bash
# macOS BSD sed requires the empty '' argument after -i
git grep -l "Channels.McpHttp" | xargs sed -i '' 's/Channels\.McpHttp/Channels.Mcp/g'
git grep -l "claude_code\.mcp_http" | xargs sed -i '' 's/claude_code\.mcp_http/claude_code.mcp_stdio/g'
git mv runtime/lib/esr/plugins/claude_code/channels/mcp_http.ex \
       runtime/lib/esr/plugins/claude_code/channels/mcp.ex
git mv runtime/test/esr/plugins/claude_code/channels/mcp_http_test.exs \
       runtime/test/esr/plugins/claude_code/channels/mcp_test.exs
```

After: full `mix test` + grep for any leftover `McpHttp` /
`claude_code\.mcp_http` substring.

## 10. Open questions

- **Q1.** WS auth for the bridge. `EsrWeb.ChannelSocket.connect/3`
  may require a session-scoped token; verify during implementation
  whether the bridge can join `cli:channel/<sid>` without auth (same
  privileges as the existing HTTP MCP route had) or needs a new
  token. If new token needed, mint in `Launcher.prepare_spawn/1`
  and pass via `--token` argv.
- **Q2.** `instructions` string verbatim from `mcp_controller.ex:148-153`
  or evolve? Tilt: verbatim for rev-3; revise in a follow-up.

## 11. Implementation phasing

Single PR. Order:

1. Extract `build_notification_params/1` → `ChannelNotification`
   module + move tests. `mix test` green.
2. Implement Python bridge `py/src/cc_channel_runner/`. Python
   unit tests with mock WS.
3. Update `Launcher.write_mcp_json/1` → `write_channel_mcp_config/1`.
   Promote `default_esrd_url/0` to `def`. Update launcher tests.
4. Rename `Channels.McpHttp` → `Channels.Mcp` via sed pass (§9.5).
   Update SSE-specific `@moduledoc` prose. Verify `mix test` green.
5. Delete `mcp_controller.ex` + router scope. Delete the migrated
   test file at original location.
6. Add `/pty:input` command via `Esr.Commands.Meta` DSL. Run
   `mix esr.gen_slash_routes`.
7. Add integration test (§8.3) + shell scenario (§8.4) + lifecycle
   tests (§8.5).
8. Manual verification: `/session:new` → CC starts → `/mcp` shows
   `esr-channel` connected + 3 tools + channel capability → Feishu
   chat text arrives in CC context as `<channel>` tag with meta —
   exactly the symptom we couldn't reproduce on 2026-05-12.

Estimated touch: **~30 files** (22 src/test rename + 5 docs +
1 new module + 1 new command + 4 new test files + 3 deletes). Net
LoC roughly flat.

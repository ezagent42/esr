# PR-3.5 — cc_mcp HTTP MCP Transport (esrd-hosted)

**Date:** 2026-05-05
**Status:** Draft (subagent review pending; user review pending)
**Closes:** Phase 3 PR-3.5; cc_mcp lifecycle decoupling from claude.

## Goal

Replace cc_mcp's stdio-bridge subprocess with an MCP server hosted
inside esrd. Today claude spawns
`python -m esr_cc_mcp.channel` per session as an MCP stdio child,
which couples the channel's lifecycle to the claude process. After
this PR:

- claude's `.mcp.json` uses `type: http, url: http://...` instead of
  `command: ...`. No subprocess; HTTP/SSE transport.
- esrd serves the MCP endpoint directly at
  `/mcp/<session_id>` on the existing Bandit listener.
- Channel state lives in BEAM (the existing
  `Esr.Entity.CCProcess` + `EsrWeb.ChannelChannel` per-session
  state). claude restart no longer kills the channel.
- `adapters/cc_mcp/` Python package is deleted.

## Why now

The Phase 3/4 status doc called this out as live debt: cc_mcp dies
with claude every restart; in-flight notifications mid-restart are
silently dropped; the ws_client ↔ stdio ↔ claude bridge is a chain
of three transports where one would suffice. PR-22/PR-24 fixed PTY
attach lifecycle but did NOT touch cc_mcp lifecycle — this PR does.

## Non-goals

- Generalising the MCP server beyond the cc_mcp surface. Today
  cc_mcp exposes ~10 tools (`reply`, `react`, `un_react`,
  `send_file`, `update_title`, `send_summary`, `kill_session`,
  `spawn_session`, `list_sessions`, `forward`); the Elixir port
  exposes the same set. Future plugins wanting their own MCP tools
  use the same plumbing but ship their own tool implementations.
- Full MCP authorization spec compliance. `localhost`-only binding
  + per-session URL is sufficient for v1; OAuth comes later if a
  remote claude (claude.ai web client) needs to connect.
- HTTP/2 or QUIC transport. Bandit speaks HTTP/1.1; that's all
  Claude Code's HTTP MCP client requires.

## Architecture

### MCP HTTP transport summary

Per Anthropic's MCP spec (HTTP transport), an MCP server exposes
**one URL** that handles:

1. **POST `/`** — JSON-RPC requests/responses (tools/list, tools/call,
   etc.). Body: a JSON-RPC envelope. Response: a JSON-RPC envelope
   (or 202 + SSE-streamed reply for long-running tools).
2. **GET `/`** with `Accept: text/event-stream` — server-sent events
   stream for server→client notifications (the
   `notifications/claude/channel` events that today come over stdio).

Both POST and GET are on the same URL. Claude Code's MCP client
keeps the SSE stream open as long as the session is alive and POSTs
tool calls in parallel.

### URL shape

```
<scheme>://<host>:<port>/mcp/<session_id>
```

`<scheme>://<host>:<port>` derives from the existing `ESR_ESRD_URL`
env var (already used by `scripts/esr-cc.sh` for the ws_client URL
— `ws://127.0.0.1:4001` is just the fallback when the env var is
unset). The HTTP form is the same authority with `ws://` → `http://`.

Operator overrides via `ESR_PUBLIC_HOST` (Tailscale, remote claude,
etc.) flow through transparently — `runtime/config/runtime.exs`
already wires `ESR_PUBLIC_HOST` into `EsrWeb.Endpoint`'s `url:`
config, so the same hostname round-trips.

Per-session URL keeps routing trivial: the path identifies the
target session, no auth header needed.

`esr-cc.sh` writes `.mcp.json` as:

```json
{
  "mcpServers": {
    "esr-channel": {
      "type": "http",
      "url": "${ESR_ESRD_HTTP_URL}/mcp/${ESR_SESSION_ID}"
    }
  }
}
```

The bash side computes `ESR_ESRD_HTTP_URL` as:

```bash
# Single source of truth: ESR_ESRD_URL (ws form). Flip scheme.
: "${ESR_ESRD_URL:=ws://127.0.0.1:4001}"
ESR_ESRD_HTTP_URL="${ESR_ESRD_URL/ws:/http:}"
ESR_ESRD_HTTP_URL="${ESR_ESRD_HTTP_URL/wss:/https:}"
```

— sed-substitution on the existing env var, no second source of
truth. Tailscale-IP / remote-claude scenarios just set
`ESR_ESRD_URL=ws://100.64.0.27:4001` and the HTTP MCP URL
follows automatically.

### Phoenix routes

```elixir
# router.ex
scope "/mcp/:session_id" do
  pipe_through :mcp

  post "/", EsrWeb.McpController, :handle_request
  get "/", EsrWeb.McpController, :handle_sse
end
```

`EsrWeb.McpController` is a thin HTTP/JSON-RPC adapter:

- `handle_request/2`: decode JSON-RPC, route to
  `Esr.Plugins.ClaudeCode.Mcp.dispatch/3` (session_id, method,
  params), encode response.
- `handle_sse/2`: open an SSE stream, subscribe the connection PID
  to the existing per-session PubSub topic
  (`cli:channel/<session_id>`), forward broadcasts as
  `event: notification\ndata: <json>\n\n` frames. Already-buffered
  notifications (from before SSE connect) flush immediately —
  reuses the buffer-and-flush pattern from
  `docs/notes/cc-mcp-pubsub-race.md`.

The MCP "session" concept is identified by the `session_id` URL
segment; no extra MCP-level session token is used.

### Tool implementations

`Esr.Plugins.ClaudeCode.Mcp.Tools.*` modules — one per MCP tool
the cc plugin exposes. Each module implements:

```elixir
@callback schema() :: map()           # JSON schema for tools/list
@callback call(session_id, params) :: {:ok, result} | {:error, reason}
```

Tool implementations are idiomatic Elixir — they call into the
existing per-session state (CCProcess, FeishuChatProxy, etc.) via
the same APIs the Python cc_mcp called over WS today.

### `cc_mcp` Python deletion

After this PR:

- `adapters/cc_mcp/` directory deleted entirely.
- `[tool.uv.sources] esr-cc-mcp = ...` in `py/pyproject.toml` removed.
- `scripts/esr-cc.sh` rewrites `.mcp.json` to the HTTP form.
- `--dangerously-load-development-channels server:esr-channel`
  flag stays — `esr-channel` is now the HTTP MCP server's
  registered name in `.mcp.json`.

The Python sidecar registration in feishu manifest's
`python_sidecars:` is unchanged (feishu still has a sidecar);
claude_code's `python_sidecars:` entry for `cc_adapter_runner`
stays because that's a different Python process (handler runner,
not MCP bridge). cc_mcp specifically — the MCP bridge — disappears.

### claude_code plugin manifest update

```yaml
# runtime/lib/esr/plugins/claude_code/manifest.yaml
declares:
  entities: [...]
  python_sidecars:
    # cc_adapter_runner stays; cc_mcp removed (MCP server is now
    # esrd-hosted, no Python sidecar).
    - adapter_type: cc_session
      python_module: cc_adapter_runner
  startup:
    module: Esr.Plugins.ClaudeCode.McpServer
    function: register_endpoint
```

The plugin's `startup:` hook registers the MCP endpoint with
`EsrWeb.Endpoint`'s router at boot. (Today the router's
`scope "/mcp"` is hardcoded; the plugin-startup hook makes it
plugin-owned so a future agent plugin — codex, gemini-cli — could
register its own MCP path.)

Actually: routes are compile-time in Phoenix. The plugin can't
*add* routes at runtime. Two options:

- **(A)** Keep `/mcp/:session_id` in core's router unconditionally,
  but make the controller dispatch to the plugin's tool registry
  (which IS runtime-mutable). The route is generic; the tool
  surface is plugin-owned.
- **(B)** Each plugin registers its own scope at compile time via
  a Phoenix router macro that reads enabled plugins. Heavy.

**Spec choice: (A).** The MCP HTTP route is a generic plugin
extension point, like `/plugin/list` is generic to all plugins.
Tool registry per-session is plugin-owned.

This means `runtime/lib/esr_web/router.ex` adds the `/mcp/:session_id`
scope unconditionally. The `EsrWeb.McpController` dispatches to
`Esr.Plugin.McpRegistry` (new — small ETS table) which the cc
plugin populates at startup with the cc-tool implementations.

A future agent plugin uses the same `Esr.Plugin.McpRegistry` to
register its own tools. The registry keys by tool name; collisions
fail loudly (let it crash).

## Failure modes

| When | Behaviour |
|---|---|
| claude restarts, esrd up | New HTTP session on same URL. esrd's per-session PubSub topic still has buffered notifications waiting. SSE flush replays them. |
| esrd restarts, claude up | Claude's MCP HTTP client gets connection-refused → reconnects on backoff. Per-session state is lost (per current esrd behavior; out of scope for this PR). |
| Tool call to non-existent session_id | 404 + JSON-RPC error envelope. claude shows the error in the channel; user retries with `/new-session`. |
| Tool call before session pid is registered | Same as today: PubSub buffer holds the call until a subscriber attaches (per `docs/notes/cc-mcp-pubsub-race.md`). |
| Malformed JSON-RPC | 400 + simple error. No try/rescue around the controller body. |
| SSE connection drops | Claude reconnects (MCP client behavior). esrd's pubsub subscription cleans up automatically when the connection PID dies. |

No try/rescue at the boundary. Bandit's per-request crash isolation
is sufficient.

## Test strategy

| Layer | Test | What it asserts |
|---|---|---|
| Unit | `EsrWeb.McpControllerTest` | POST `/mcp/<sid>/` with `tools/list` returns the registered tool names. POST with `tools/call reply text=ack` invokes `Esr.Plugins.ClaudeCode.Mcp.Tools.Reply.call/2`. |
| Unit | `Esr.Plugin.McpRegistryTest` | register/3 + lookup by tool name. Collision raises. |
| Integration | `EsrWeb.McpSseTest` | GET `/mcp/<sid>/` with `Accept: text/event-stream` opens SSE; broadcasting a notification on `cli:channel/<sid>` sends an `event: notification\ndata: …` frame. |
| **e2e (load-bearing)** | `tests/e2e/scenarios/06_pty_attach.sh` | Already exercises a real claude+cc_mcp roundtrip. After this PR, the same scenario runs with `.mcp.json` HTTP form — the e2e PASS is what proves "operator workflow unchanged." |
| **Invariant** | `Esr.Plugins.IsolationTest` extension | Add a new assertion: no `Esr.Plugins.ClaudeCode.*` reference in `runtime/lib/esr_web/`'s controller / router (specifically: `EsrWeb.McpController` must not name the cc plugin module by static reference; it dispatches via the registry). |

## Diff size estimate

- `runtime/lib/esr_web/router.ex`: **+5 LOC** (`/mcp/:session_id` scope)
- `runtime/lib/esr_web/mcp_controller.ex` (new): **+150 LOC** (POST + SSE handlers)
- `runtime/lib/esr/plugin/mcp_registry.ex` (new): **+50 LOC** (ETS-backed tool registry)
- `runtime/lib/esr/plugins/claude_code/mcp.ex` (new): **+30 LOC** (`register_endpoint/0` startup hook + tool list)
- `runtime/lib/esr/plugins/claude_code/mcp/tools/*.ex` (new, ~10 modules): **+400 LOC** (one tool per ~40 LOC; bodies port the existing cc_mcp tool logic to Elixir)
- `runtime/lib/esr/plugins/claude_code/manifest.yaml`: **+5 LOC** (`startup:` block; cc_mcp sidecar entry deleted)
- `scripts/esr-cc.sh`: **−10 LOC** (delete `command:` block, write `url:` form)
- `adapters/cc_mcp/`: **−~1500 LOC** (entire dir deleted)
- `py/pyproject.toml`: **−1 LOC** (`esr-cc-mcp` source removed)
- Tests: **+250 LOC** (new) **−~800 LOC** (cc_mcp tests deleted)

**Net: ~+900 LOC added, ~−2310 LOC deleted = ~−1400 LOC.** Net
DELETION because the Python ws_client + stdio bridge + per-tool
adapter goes away.

## Roll-back

Revert is clean: cc_mcp/ comes back; `.mcp.json` template flips to
`command:`; controller + registry + tools deleted; router scope
removed. The Phase D-1 + D-2 gains are unaffected (this PR is
strictly cc_mcp lifecycle work).

## Resolved design questions (let-it-crash position)

- **Per-session URL or query param?** URL path (`/mcp/<session_id>`).
  Cleaner routing, no header parsing needed.
- **Auth?** localhost binding + URL secrecy. No auth header for v1.
  When a remote claude.ai client needs to connect, add token-based
  auth as Phase E-2.
- **Tool registry collision?** raise. Let it crash (memory rule).
- **SSE vs long-poll for notifications?** SSE. MCP HTTP transport
  spec mandates SSE for server→client.
- **What if a tool body raises?** Propagates to Bandit;
  per-request 500 + JSON-RPC error envelope formatted by a single
  catch-all clause in McpController. The 500 is the let-it-crash
  signal; subsequent calls on the same SSE stream still work.

## Open questions for user (林懿伦)

1. **Should the MCP route live in `runtime/lib/esr_web/router.ex`
   (option A — chosen)** or be plugin-registered via a Phoenix
   router macro (option B — heavier)? Spec defaults to A on the
   "compile-time routes are simpler" argument.
2. **Where do plugin tools live in the source tree?**
   `runtime/lib/esr/plugins/claude_code/mcp/tools/` (per-tool
   module) is the spec assumption. Confirm vs alternative
   `runtime/lib/esr/plugins/claude_code/mcp.ex` as a single
   ~400-LOC module.
3. **Backwards compat window?** Spec assumes hard cutover —
   `cc_mcp/` deleted in same PR, `.mcp.json` flipped, no
   transitional dual-stack. Operators on a fresh `git pull` get
   the HTTP transport directly.

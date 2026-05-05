defmodule EsrWeb.Router do
  use EsrWeb, :router

  # PR-23: minimal :browser pipeline. Phoenix Channel WebSockets go
  # through Endpoint's `socket/3` (not the Plug router pipeline); this
  # pipeline only serves the static HTML shell at the attach route.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers
  end

  scope "/", EsrWeb do
    pipe_through :browser

    # PR-23: HTTP path mirrors esr URI segments. Page boots xterm.js
    # and opens a Phoenix.Channel to attach:<sid> (see attach_socket.ex
    # + attach_channel.ex).
    get "/sessions/:sid/attach", AttachController, :show
  end

  # Phase 2 PR-2.1: schema dump for escript / REPL / doc generation.
  scope "/admin", EsrWeb do
    get "/slash_schema.json", SlashSchemaController, :show
  end

  # PR-3.5 (2026-05-05): HTTP MCP transport. Replaces the Python
  # `adapters/cc_mcp/` stdio bridge — claude connects via
  # `.mcp.json type: http, url: <esrd>/mcp/<session_id>`. POST handles
  # JSON-RPC requests; GET with `Accept: text/event-stream` opens the
  # SSE notification stream. See
  # `docs/superpowers/specs/2026-05-05-pr-3-5-http-mcp-transport.md`.
  scope "/mcp/:session_id", EsrWeb do
    post "/", McpController, :handle_request
    get "/", McpController, :handle_sse
  end

  # DIAGNOSTIC (temporary 2026-05-02 — PR-24 bidirectional verification).
  # Curl-driven injection of a `notification` envelope onto a session's
  # `cli:channel/<sid>` PubSub topic. Used to verify cc_mcp's inbound path
  # (Phoenix.PubSub broadcast → cc_mcp → claude `<channel>` tag) without
  # involving the FAA / Feishu API. Remove after the verification flow
  # is documented + the auto-confirm decision lands.
  scope "/debug", EsrWeb do
    get "/inject_notification/:sid", DebugController, :inject_notification
    # Diagnostic PTY stdin write (writes via Esr.Entity.PtyProcess.write/2).
    # Used by tools/esr-debug send-keys.
    post "/pty_send/:sid", DebugController, :pty_send
    get "/pty_send/:sid", DebugController, :pty_send
  end
end

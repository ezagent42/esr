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

    # PR-23: HTTP path serves the xterm.js attach shell.
    # PR 2026-05-09: dropped the `:sid` path param. Auth is now via a
    # `?token=<phoenix_token>` query param (HMAC-signed actor_id, salt
    # "pty_attach", 10-minute TTL); the path no longer leaks the
    # actor_id. AttachController verifies the token before rendering.
    # Path is `/ptys/attach` to match the slash resource (`/pty:attach`)
    # and `Esr.Uri` path-style type `ptys` (consistent with `workspaces`,
    # `sessions`, `users`, etc.). Earlier draft used `/sessions/attach`
    # but PTY actor_ids are no longer nested under sessions in the
    # session-first metamodel.
    get "/ptys/attach", AttachController, :show
  end

  # Phase 2 PR-2.1: schema dump for escript / REPL / doc generation.
  scope "/admin", EsrWeb do
    get "/slash_schema.json", SlashSchemaController, :show
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

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

  # DIAGNOSTIC (temporary 2026-05-02 — PR-24 bidirectional verification).
  # Curl-driven injection of a `notification` envelope onto a session's
  # `cli:channel/<sid>` PubSub topic. Used to verify cc_mcp's inbound path
  # (Phoenix.PubSub broadcast → cc_mcp → claude `<channel>` tag) without
  # involving the FAA / Feishu API. Remove after the verification flow
  # is documented + the auto-confirm decision lands.
  scope "/debug", EsrWeb do
    get "/inject_notification/:sid", DebugController, :inject_notification
  end
end

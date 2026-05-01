defmodule EsrWeb.Router do
  use EsrWeb, :router

  # PR-22: browser pipeline for the LiveView attach surface. Pre-PR-22
  # esrd served only Phoenix Channels over WebSocket (no HTML routes).
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EsrWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", EsrWeb do
    pipe_through :browser

    # PR-22: HTTP path mirrors esr URI segments (Esr.Uri:
    # esr://localhost/sessions/<sid>/attach). The /attach slash returns
    # this URL via Esr.Uri.to_http_url/2.
    live "/sessions/:sid/attach", AttachLive
  end
end

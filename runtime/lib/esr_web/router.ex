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
end

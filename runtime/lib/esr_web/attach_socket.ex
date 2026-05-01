defmodule EsrWeb.AttachSocket do
  @moduledoc """
  Phoenix.Socket for browser-side terminal attach (PR-23, replaces
  the PR-22 LiveView path).

  Browsers connecting to `/attach_socket/websocket` join topic
  `attach:<session_id>`. `EsrWeb.AttachChannel` subscribes the joined
  channel to the session's `pty:<sid>` PubSub topic, forwarding
  PtyProcess stdout chunks to the client and routing client `stdin` /
  `resize` events back into the BEAM peer.

  No DOM diffing here (vs LiveView), so xterm.js owns its container
  uncontested — fixes the rendering jitter operators reported on PR-22.
  """
  use Phoenix.Socket

  channel "attach:*", EsrWeb.AttachChannel

  @impl Phoenix.Socket
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl Phoenix.Socket
  def id(_socket), do: nil
end

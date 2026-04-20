defmodule EsrWeb.ChannelSocket do
  @moduledoc """
  Phoenix.Socket for esr-channel MCP bridges (spec §3.2).

  Each CC session's MCP child process opens one WebSocket against
  `/channel/socket/websocket?vsn=2.0.0` and joins a topic
  `cli:channel/<session_id>`. `EsrWeb.ChannelChannel` handles
  register / tool_invoke / notification / session_killed frames.
  """
  use Phoenix.Socket

  channel "cli:channel/*", EsrWeb.ChannelChannel

  @impl Phoenix.Socket
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl Phoenix.Socket
  def id(_socket), do: nil
end

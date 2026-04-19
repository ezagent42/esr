defmodule EsrWeb.HandlerSocket do
  @moduledoc """
  Phoenix.Socket for handler-worker processes connecting to the
  runtime (PRD 01 F12, spec §7.1).

  One WebSocket per Python worker process, joined against
  ``handler:<module>/<worker_id>`` topics (see `EsrWeb.HandlerChannel`).
  """

  use Phoenix.Socket

  channel "handler:*", EsrWeb.HandlerChannel
  channel "cli:*", EsrWeb.CliChannel

  @impl Phoenix.Socket
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl Phoenix.Socket
  def id(_socket), do: nil
end

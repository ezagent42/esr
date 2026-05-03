defmodule EsrWeb.AdapterSocket do
  @moduledoc """
  Phoenix.Socket for adapter processes connecting to the runtime
  (PRD 01 F09, spec §7.1).

  Each Python adapter opens one WebSocket against ``/adapter_hub/socket``
  and joins one topic per adapter instance — the channel module
  (`EsrWeb.AdapterChannel`) routes inbound Feishu envelopes into the
  new peer chain via `Esr.Entities.FeishuAppAdapter` (post-P2-16; the
  previous `Esr.AdapterHub.Registry` lookup was removed).
  """

  use Phoenix.Socket

  channel "adapter:*", EsrWeb.AdapterChannel

  @impl Phoenix.Socket
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl Phoenix.Socket
  def id(_socket), do: nil
end

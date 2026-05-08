defmodule Esr.Interface.Boundary do
  @moduledoc """
  Boundary contract per session.md §五 Adapter:

  > 职责：跟外部系统（消息平台、API、外部服务）的桥梁。把外部协议
  > 翻译成 ESR 内部 envelope。
  > 实现的 Interface: BoundaryInterface — inbound / outbound 翻译

  Current implementers (post-R11): aspirational. Future Adapter
  Entities (FeishuAppAdapter, future Slack/Discord/Aider adapters)
  should declare `@behaviour Esr.Interface.Boundary` once their
  inbound/outbound API surface is normalized.

  Today's `Esr.Entity.FeishuAppAdapter` uses hand-rolled functions
  with bespoke names (`forward_to_chain/2`, `send_directive/2`); a
  future R-batch will normalize these to `inbound/2` + `outbound/2`
  and adopt the @behaviour.

  See session.md §七 (BoundaryInterface).
  """

  @doc """
  Translate an inbound message from the external protocol into ESR's
  internal envelope shape, then deliver downstream.
  """
  @callback inbound(external_msg :: term(), ctx :: map()) :: :ok | {:error, term()}

  @doc """
  Translate an outbound ESR envelope into the external protocol's
  shape, then send.
  """
  @callback outbound(envelope :: map(), ctx :: map()) :: :ok | {:error, term()}
end

defmodule Esr.Interface.BoundaryConnection do
  @moduledoc """
  BoundaryConnection contract per session.md §五 Adapter:

  > 默认占有的 Resource:
  > - 1 ExternalConnection Resource (实现 BoundaryConnectionInterface)

  The connection itself (WebSocket, SSE, HTTP-stream) is a Resource
  used by an Adapter Entity. This Interface contracts its lifecycle:
  connect / reconnect / disconnect.

  See session.md §七 (BoundaryConnectionInterface).
  """

  @callback connect(ctx :: map()) :: {:ok, ref :: term()} | {:error, term()}
  @callback reconnect(ref :: term(), ctx :: map()) :: :ok | {:error, term()}
  @callback disconnect(ref :: term()) :: :ok
end

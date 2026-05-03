defmodule Esr.Interface.Channel do
  @moduledoc """
  Channel Resource contract per session.md §六 Channel:

  > 职责：两个或多个 Entity 之间的消息流。
  > 实现的 Interface: ChannelInterface — publish / subscribe / unsubscribe / frame

  Today's ESR uses Phoenix.PubSub + Phoenix.Channel as the underlying
  Channel mechanism; this Interface wraps the metamodel-level contract.

  Current implementers (post-R11): aspirational — no concrete module
  declares this @behaviour today. Phoenix.PubSub + Phoenix.Channel
  collectively satisfy the contract through framework code, not via
  ESR module declarations. Future PR (e.g. when R-future channel
  abstraction lands per `docs/issues/02-cc-mcp-decouple-from-claude.md`)
  may wrap them in an ESR module that declares `@behaviour`.

  See session.md §七 (ChannelInterface).
  """

  @doc "Publish `msg` to all subscribers of `channel`."
  @callback publish(channel :: term(), msg :: term()) :: :ok

  @doc "Subscribe the calling process to `channel`."
  @callback subscribe(channel :: term()) :: :ok | {:error, term()}

  @doc "Unsubscribe the calling process from `channel`."
  @callback unsubscribe(channel :: term()) :: :ok

  @doc """
  Optional framing — convert a domain message to/from the channel's
  wire format. Default behaviour: identity (`msg` returned unchanged).
  """
  @callback frame(msg :: term()) :: term()

  @optional_callbacks frame: 1
end

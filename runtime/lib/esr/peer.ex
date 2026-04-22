defmodule Esr.Peer do
  @moduledoc """
  Base behaviour for all Peers.

  Peers are actors that implement one of `Esr.Peer.Proxy` or `Esr.Peer.Stateful`.
  Every Peer belongs to exactly one Session (user Session or `AdminSession`).

  See `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` §3.1.
  """

  @type peer_kind :: :proxy | :stateful

  @callback peer_kind() :: peer_kind()

  @doc "Common helpers for modules using Peer.Proxy or Peer.Stateful."
  defmacro __using__(opts) do
    kind = Keyword.fetch!(opts, :kind)

    quote do
      @behaviour Esr.Peer

      @impl Esr.Peer
      def peer_kind, do: unquote(kind)
    end
  end
end

defmodule Esr.Entity do
  @moduledoc """
  Base behaviour for all Peers.

  Peers are actors that implement one of `Esr.Entity.Proxy` or `Esr.Entity.Stateful`.
  Every Peer belongs to exactly one Session (user Session or `Scope.Admin`).

  See `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` §3.1.
  """

  @type peer_kind :: :proxy | :stateful

  @callback peer_kind() :: peer_kind()

  @doc """
  Optional: build the `init_args` map a peer needs at spawn time from
  the session-create `params`. `Scope.Router.spawn_pipeline/3` looks
  this up generically (via `function_exported?/3`) so adding a new
  Stateful peer never requires a Scope.Router edit.

  Peers that don't override return `%{}` via `default_spawn_args/1`.
  """
  @callback spawn_args(params :: map()) :: map()
  @optional_callbacks spawn_args: 1

  @doc false
  def default_spawn_args(_params), do: %{}

  @doc """
  Fetch a spawn-args param that may be keyed by atom (Elixir callers)
  or string (yaml/JSON callers). Used by `spawn_args/1` implementations
  to accept both shapes uniformly.
  """
  @spec get_param(map(), atom()) :: any()
  def get_param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  @doc "Common helpers for modules using Peer.Proxy or Peer.Stateful."
  defmacro __using__(opts) do
    kind = Keyword.fetch!(opts, :kind)

    quote do
      @behaviour Esr.Entity

      @impl Esr.Entity
      def peer_kind, do: unquote(kind)
    end
  end
end

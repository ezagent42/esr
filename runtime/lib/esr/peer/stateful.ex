defmodule Esr.Peer.Stateful do
  @moduledoc """
  Peer with state and/or side effects.

  See spec §3.1.
  """

  @callback init(peer_args :: map()) ::
              {:ok, state :: term()} | {:stop, reason :: term()}

  @callback handle_upstream(msg :: term(), state :: term()) ::
              {:forward, [term()], term()}
              | {:reply, term(), term()}
              | {:drop, atom(), term()}

  @callback handle_downstream(msg :: term(), state :: term()) ::
              {:forward, [term()], term()}
              | {:drop, atom(), term()}

  defmacro __using__(_opts) do
    quote do
      use Esr.Peer, kind: :stateful
      @behaviour Esr.Peer.Stateful
    end
  end
end

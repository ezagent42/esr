defmodule Esr.Peer.Stateful do
  @moduledoc """
  Peer with state and/or side effects.

  A Peer.Stateful is hosted by a GenServer (or an `Esr.OSProcess`
  GenServer for peers that own an OS subprocess). This behaviour
  does NOT redeclare `init/1` — that's GenServer's contract. What
  Peer.Stateful adds on top are the chain-specific callbacks:

    * `handle_upstream/2` — consume a message travelling FROM upstream
      peers/OS stdout, optionally emit forwarded messages, update state.
    * `handle_downstream/2` — consume a message travelling TO downstream
      peers/OS stdin, same shape.

  See spec §3.1. Prior to PR-5 this behaviour also declared
  `init/1`, which collided with GenServer's identically-named
  callback and produced a "conflicting behaviours found" compile
  warning on every module that did both `use Esr.Peer.Stateful`
  and `use GenServer`. PR-5 drops the duplicate so the warning
  goes away; peers continue to implement `init/1` as a GenServer
  callback (or an OSProcess one).
  """

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

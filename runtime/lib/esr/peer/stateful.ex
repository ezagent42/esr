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

  ## PR-6 B1 — overridable defaults + shared GenServer↔Stateful bridge

  `use Esr.Peer.Stateful` now injects three overridable defaults so
  peers that only need stock behaviour stop carrying boilerplate:

    * `start_link/1` — accepts either `map()` or `keyword()`;
      normalises the keyword shape to a map before handing off to
      `GenServer.start_link/2`. Peers that need to pre-process args
      (e.g. VoiceE2E adding `:subscriber`) override this.
    * `handle_upstream/2` — returns `{:forward, [], state}` by default.
    * `handle_downstream/2` — returns `{:forward, [], state}` by default.

  All three are declared `defoverridable`, so peers can still define
  specific pattern-matched clauses when they participate in the chain.

  Plus `Esr.Peer.Stateful.dispatch_upstream/3` (and the downstream
  twin) is a public helper that translates a handle_upstream result
  into a `handle_info/2`-shaped reply. Drop it into `handle_info/2`:

      def handle_info(msg, state),
        do: Esr.Peer.Stateful.dispatch_upstream(msg, state, __MODULE__)

  Peers that need stricter match semantics (`FeishuChatProxy`'s
  drop-only invariant from PR-5 — the `{:drop, _, ns} = ...` pattern
  is a deliberate forcing function that crashes on an unexpected
  `{:forward, …}` return) keep their inline pattern match. The
  bridge is a default, not a mandate.
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

      # Default dual-shape start_link: accept both `map()` (unit-test
      # convention) and `keyword()` (Esr.PeerPool's `worker_mod.start_link([])`
      # convention). Peers that need to pre-process args override this.
      def start_link(args) when is_map(args),
        do: GenServer.start_link(__MODULE__, args)

      def start_link(args) when is_list(args),
        do: GenServer.start_link(__MODULE__, Map.new(args))

      # No-op defaults for the two chain callbacks. Peers that
      # actually participate in the chain override with specific clauses.
      @impl Esr.Peer.Stateful
      def handle_upstream(_msg, state), do: {:forward, [], state}

      @impl Esr.Peer.Stateful
      def handle_downstream(_msg, state), do: {:forward, [], state}

      defoverridable start_link: 1,
                     handle_upstream: 2,
                     handle_downstream: 2
    end
  end

  @doc """
  GenServer→Stateful bridge for `handle_upstream/2`.

  Invokes `mod.handle_upstream(msg, state)` and translates every
  documented result tuple into the `{:noreply, new_state}` shape
  expected by `GenServer.handle_info/2`.

  Use this when a peer's `handle_info/2` for the messages it consumes
  is nothing more than "invoke the stateful callback and forget the
  outbound list". Peers that need stricter semantics (e.g. "crash if
  the callback ever returns `{:forward, _, _}`") keep their inline
  match — the bridge is a default, not a mandate.
  """
  @spec dispatch_upstream(term(), term(), module()) :: {:noreply, term()}
  def dispatch_upstream(msg, state, mod) do
    case mod.handle_upstream(msg, state) do
      {:forward, _outbound, new_state} -> {:noreply, new_state}
      {:drop, _reason, new_state} -> {:noreply, new_state}
      {:reply, _reply, new_state} -> {:noreply, new_state}
    end
  end

  @doc """
  GenServer→Stateful bridge for `handle_downstream/2`. Twin of
  `dispatch_upstream/3`; `handle_downstream/2` may not return
  `{:reply, ...}` per the behaviour, so the shape is narrower.
  """
  @spec dispatch_downstream(term(), term(), module()) :: {:noreply, term()}
  def dispatch_downstream(msg, state, mod) do
    case mod.handle_downstream(msg, state) do
      {:forward, _outbound, new_state} -> {:noreply, new_state}
      {:drop, _reason, new_state} -> {:noreply, new_state}
    end
  end
end

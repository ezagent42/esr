defmodule Esr.PeerServer do
  @moduledoc """
  GenServer for one live actor (PRD 01 F05). State held here; event
  handling (F06), action dispatch (F07), dedup (F05), pause/resume
  (F20) follow in subsequent FRs.

  Every PeerServer is registered under its `actor_id` in
  `Esr.PeerRegistry` via the `{:via, Registry, ...}` name. Telemetry
  `[:esr, :actor, :spawned]` fires in `init/1`.
  """

  use GenServer

  defstruct [
    :actor_id,
    :actor_type,
    :handler_module,
    :state,
    adapter_refs: %{},
    metadata: %{},
    dedup_keys: MapSet.new(),
    paused: false
  ]

  @type t :: %__MODULE__{
          actor_id: String.t(),
          actor_type: String.t(),
          handler_module: String.t(),
          state: map(),
          adapter_refs: map(),
          metadata: map(),
          dedup_keys: MapSet.t(String.t()),
          paused: boolean()
        }

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    actor_id = Keyword.fetch!(opts, :actor_id)
    GenServer.start_link(__MODULE__, opts, name: via(actor_id))
  end

  @spec get_state(String.t()) :: map()
  def get_state(actor_id) do
    GenServer.call(via(actor_id), :get_state)
  end

  defp via(actor_id), do: {:via, Registry, {Esr.PeerRegistry, actor_id}}

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %__MODULE__{
      actor_id: Keyword.fetch!(opts, :actor_id),
      actor_type: Keyword.fetch!(opts, :actor_type),
      handler_module: Keyword.fetch!(opts, :handler_module),
      state: Keyword.get(opts, :initial_state, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    :telemetry.execute([:esr, :actor, :spawned], %{}, %{
      actor_id: state.actor_id,
      actor_type: state.actor_type
    })

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_state, _from, %__MODULE__{state: s} = acc) do
    {:reply, s, acc}
  end
end

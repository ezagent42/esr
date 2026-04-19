defmodule Esr.PeerServer do
  @moduledoc """
  GenServer for one live actor (PRD 01 F05 / F06 / F07).

  Holds per-actor state and processes events synchronously:
   1. On `{:inbound_event, envelope}` from AdapterChannel (F09), dedup
      by the event's ``idempotency_key`` (bounded MapSet), call
      `Esr.HandlerRouter.call/3` (F11), persist the new state, and
      dispatch the returned actions (F07).
   2. Emit `[:esr, :handler, :invoked]` telemetry on success,
      `[:esr, :handler, :error]` on failure (both with actor_id +
      event_id).

  Every PeerServer is registered under its `actor_id` in
  `Esr.PeerRegistry` via `{:via, Registry, ...}`; telemetry
  `[:esr, :actor, :spawned]` fires in init/1.
  """

  use GenServer

  alias Esr.HandlerRouter

  @default_handler_timeout 5_000

  defstruct [
    :actor_id,
    :actor_type,
    :handler_module,
    :state,
    handler_timeout: @default_handler_timeout,
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
          handler_timeout: pos_integer(),
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
      handler_timeout: Keyword.get(opts, :handler_timeout, @default_handler_timeout),
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

  @impl GenServer
  def handle_info({:inbound_event, envelope}, %__MODULE__{} = state) do
    idempotency_key = extract_idempotency_key(envelope)

    if idempotency_key && MapSet.member?(state.dedup_keys, idempotency_key) do
      :telemetry.execute([:esr, :handler, :dedup_drop], %{}, %{
        actor_id: state.actor_id,
        idempotency_key: idempotency_key
      })
      {:noreply, state}
    else
      {:noreply, invoke_handler(state, envelope, idempotency_key)}
    end
  end

  def handle_info({:directive_ack, _envelope}, %__MODULE__{} = state) do
    # directive_ack correlation lives in the emitter (v0.1 minimal).
    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # Event invocation pipeline (F06)
  # ------------------------------------------------------------------

  defp invoke_handler(%__MODULE__{} = state, envelope, idempotency_key) do
    payload = %{
      "state" => state.state,
      "event" => Map.get(envelope, "payload", %{})
    }

    event_id = Map.get(envelope, "id", "")

    case HandlerRouter.call(state.handler_module, payload, state.handler_timeout) do
      {:ok, new_state, _actions} when is_map(new_state) ->
        :telemetry.execute([:esr, :handler, :invoked], %{}, %{
          actor_id: state.actor_id,
          event_id: event_id
        })

        state
        |> Map.put(:state, new_state)
        |> record_dedup(idempotency_key)

      {:error, reason} ->
        :telemetry.execute([:esr, :handler, :error], %{}, %{
          actor_id: state.actor_id,
          event_id: event_id,
          reason: reason
        })

        state
    end
  end

  defp record_dedup(%__MODULE__{} = state, nil), do: state

  defp record_dedup(%__MODULE__{dedup_keys: keys} = state, key)
       when is_binary(key) do
    %__MODULE__{state | dedup_keys: MapSet.put(keys, key)}
  end

  defp extract_idempotency_key(envelope) do
    case get_in(envelope, ["payload", "args", "idempotency_key"]) do
      key when is_binary(key) -> key
      _ -> nil
    end
  end
end

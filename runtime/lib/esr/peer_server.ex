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
  @pause_queue_limit 1_000

  defstruct [
    :actor_id,
    :actor_type,
    :handler_module,
    :state,
    handler_timeout: @default_handler_timeout,
    adapter_refs: %{},
    metadata: %{},
    dedup_keys: MapSet.new(),
    paused: false,
    pending_events: []
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
          paused: boolean(),
          pending_events: [map()]
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

  @spec pause(String.t()) :: :ok
  def pause(actor_id) do
    GenServer.call(via(actor_id), :pause)
  end

  @spec resume(String.t()) :: :ok
  def resume(actor_id) do
    GenServer.call(via(actor_id), :resume)
  end

  @spec pending_count(String.t()) :: non_neg_integer()
  def pending_count(actor_id) do
    GenServer.call(via(actor_id), :pending_count)
  end

  defp via(actor_id), do: {:via, Registry, {Esr.PeerRegistry, actor_id}}

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

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
  def terminate(_reason, %__MODULE__{actor_id: actor_id, actor_type: actor_type}) do
    :telemetry.execute([:esr, :peer_server, :stopped], %{}, %{
      actor_id: actor_id,
      actor_type: actor_type
    })

    :ok
  end

  @impl GenServer
  def handle_call(:get_state, _from, %__MODULE__{state: s} = acc) do
    {:reply, s, acc}
  end

  def handle_call(:pause, _from, %__MODULE__{} = state) do
    :telemetry.execute([:esr, :actor, :paused], %{}, %{actor_id: state.actor_id})
    {:reply, :ok, %__MODULE__{state | paused: true}}
  end

  def handle_call(:resume, _from, %__MODULE__{} = state) do
    # pending_events is stored newest-at-head; replay in arrival order.
    for envelope <- Enum.reverse(state.pending_events) do
      send(self(), {:inbound_event, envelope})
    end

    :telemetry.execute([:esr, :actor, :resumed], %{}, %{
      actor_id: state.actor_id,
      drained: length(state.pending_events)
    })

    {:reply, :ok, %__MODULE__{state | paused: false, pending_events: []}}
  end

  def handle_call(:pending_count, _from, %__MODULE__{pending_events: q} = state) do
    {:reply, length(q), state}
  end

  @impl GenServer
  def handle_info({:inbound_event, envelope}, %__MODULE__{paused: true} = state) do
    if length(state.pending_events) >= @pause_queue_limit do
      {:noreply, state}
    else
      {:noreply, %__MODULE__{state | pending_events: [envelope | state.pending_events]}}
    end
  end

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
      {:ok, new_state, actions} when is_map(new_state) and is_list(actions) ->
        :telemetry.execute([:esr, :handler, :invoked], %{}, %{
          actor_id: state.actor_id,
          event_id: event_id
        })

        Enum.each(actions, &dispatch_action(&1, state.actor_id))

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

  # ------------------------------------------------------------------
  # Action dispatch (F07)
  # ------------------------------------------------------------------

  defp dispatch_action(%{"type" => "emit"} = action, actor_id) do
    adapter = action["adapter"]
    topic = "adapter:" <> adapter

    envelope = %{
      "id" => "d-" <> Integer.to_string(System.unique_integer([:positive])),
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "type" => "directive",
      "source" => "esr://localhost/actor/" <> actor_id,
      "payload" => %{
        "adapter" => adapter,
        "action" => action["action"],
        "args" => Map.get(action, "args", %{})
      }
    }

    EsrWeb.Endpoint.broadcast(topic, "directive", envelope)

    :telemetry.execute([:esr, :emit, :dispatched], %{}, %{
      actor_id: actor_id,
      adapter: adapter,
      action: action["action"]
    })
  end

  defp dispatch_action(%{"type" => "route", "target" => target, "msg" => msg}, actor_id) do
    case Registry.lookup(Esr.PeerRegistry, target) do
      [{pid, _}] ->
        send(pid, {:inbound_event, %{"payload" => msg}})

      [] ->
        :telemetry.execute([:esr, :route, :target_missing], %{}, %{
          actor_id: actor_id,
          target: target
        })
    end
  end

  defp dispatch_action(%{"type" => "invoke_command"} = action, actor_id) do
    # F13 Topology.Instantiator wires this for real; for now just
    # emit telemetry so the plumbing is observable.
    :telemetry.execute([:esr, :invoke_command, :received], %{}, %{
      actor_id: actor_id,
      name: action["name"],
      params: Map.get(action, "params", %{})
    })
  end

  defp dispatch_action(unknown, actor_id) do
    :telemetry.execute([:esr, :action, :unknown], %{}, %{
      actor_id: actor_id,
      action: unknown
    })
  end
end

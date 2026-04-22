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
  @behaviour Esr.Handler
  require Logger

  alias Esr.HandlerRouter
  alias Esr.Persistence.Ets, as: PersistStore
  alias Esr.Topology.Instantiator, as: TopoInstantiator
  alias Esr.Topology.Registry, as: TopoRegistry

  @doc """
  Built-in MCP tool names exposed by `build_emit_for_tool/3`
  (see `lib/esr/peer_server.ex` §"build_emit_for_tool" clauses).
  CAP-4 derives required permissions as `workspace:<ws>/<tool_name>`,
  so these four names must be registered in `Esr.Permissions.Registry`
  at boot or every tool_invoke would be denied.
  """
  @impl Esr.Handler
  def permissions, do: ["reply", "react", "send_file", "_echo", "session.signal_cleanup"]

  @default_handler_timeout 5_000
  @default_directive_timeout 30_000
  @pause_queue_limit 1_000
  @dedup_limit 1_000
  @persist_table :esr_actor_states

  defstruct [
    :actor_id,
    :actor_type,
    :handler_module,
    :state,
    handler_timeout: @default_handler_timeout,
    directive_timeout: @default_directive_timeout,
    adapter_refs: %{},
    metadata: %{},
    dedup_keys: MapSet.new(),
    dedup_order: :queue.new(),
    paused: false,
    pending_events: [],
    pending_directives: %{},
    pending_tool_reqs: %{}
  ]

  @type t :: %__MODULE__{
          actor_id: String.t(),
          actor_type: String.t(),
          handler_module: String.t(),
          state: map(),
          handler_timeout: pos_integer(),
          directive_timeout: pos_integer(),
          adapter_refs: map(),
          metadata: map(),
          dedup_keys: MapSet.t(String.t()),
          dedup_order: :queue.queue(String.t()),
          paused: boolean(),
          pending_events: [map()],
          pending_directives: %{String.t() => map()},
          pending_tool_reqs: %{String.t() => {String.t(), pid()}}
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

  @doc """
  Returns a snapshot of the peer's public introspection fields
  (`actor_id`, `actor_type`, `handler_module`, `paused`, `state`).
  Used by `EsrWeb.CliChannel` for `cli:actors/inspect`.
  """
  @spec describe(String.t()) :: map()
  def describe(actor_id) do
    GenServer.call(via(actor_id), :describe)
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

    actor_id = Keyword.fetch!(opts, :actor_id)
    initial_state = Keyword.get(opts, :initial_state, %{})

    # Spec §7.4 / F18: if the ETS store has a prior state for this
    # actor_id, rehydrate it (prior state wins — it represents the
    # last committed handler transition). Falls through to
    # initial_state on a fresh spawn.
    rehydrated =
      case PersistStore.get(@persist_table, actor_id) do
        {:ok, prior} -> prior
        :error -> initial_state
      end

    state = %__MODULE__{
      actor_id: actor_id,
      actor_type: Keyword.fetch!(opts, :actor_type),
      handler_module: Keyword.fetch!(opts, :handler_module),
      state: rehydrated,
      handler_timeout: Keyword.get(opts, :handler_timeout, @default_handler_timeout),
      directive_timeout: Keyword.get(opts, :directive_timeout, @default_directive_timeout),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    :telemetry.execute([:esr, :actor, :spawned], %{}, %{
      actor_id: state.actor_id,
      actor_type: state.actor_type
    })

    Logger.info("actor_spawned actor_id=#{state.actor_id} actor_type=#{state.actor_type}")

    {:ok, state}
  end

  @impl GenServer
  def terminate(_reason, %__MODULE__{actor_id: actor_id, actor_type: actor_type}) do
    :telemetry.execute([:esr, :peer_server, :stopped], %{}, %{
      actor_id: actor_id,
      actor_type: actor_type
    })

    # REMOVED (P2-15): feishu_thread_proxy-specific log moved to
    # Esr.Peers.FeishuChatProxy's terminate/2 in PR-3 when the actor_type
    # lane retires.

    :ok
  end

  @impl GenServer
  def handle_call(:get_state, _from, %__MODULE__{state: s} = acc) do
    {:reply, s, acc}
  end

  def handle_call(:describe, _from, %__MODULE__{} = acc) do
    snapshot = %{
      actor_id: acc.actor_id,
      actor_type: acc.actor_type,
      handler_module: acc.handler_module,
      paused: acc.paused,
      state: acc.state
    }

    {:reply, snapshot, acc}
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
    # Capabilities spec §7.2 (CAP-4) — Lane B inbound enforcement.
    # AdapterChannel.handle_in("event", ...) has already rejected
    # envelopes missing principal_id, so a well-formed ingress path
    # always has one. For direct test/route sends that bypass the
    # adapter channel (e.g. route action at peer_server.ex:618), a
    # missing or non-binary principal_id means "no grant" → deny.
    principal_id = envelope["principal_id"]
    workspace = envelope["workspace_name"]
    event_type = get_in(envelope, ["payload", "event_type"])
    required = "workspace:#{workspace || "*"}/#{permission_for_event(event_type)}"

    if capability_granted?(principal_id, required) do
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
    else
      :telemetry.execute(
        [:esr, :capabilities, :denied],
        %{count: 1},
        %{
          principal_id: principal_id,
          required_perm: required,
          lane: :B_inbound,
          actor_id: state.actor_id
        }
      )

      # Drop silently — Lane A handles the user-facing deny response.
      {:noreply, state}
    end
  end

  # v0.2 §3.2 — tool_invoke arrives from ChannelChannel, we emit to the
  # real adapter and WAIT for directive_ack before replying tool_result.
  #
  # Capabilities spec §6.3 / §7.3 (CAP-4): arity 6 carries ``principal_id``
  # (the identity that invoked the tool, as captured by ChannelChannel on
  # ``session_register``). Lane B enforces ``workspace:<ws>/<tool>`` here —
  # denied calls emit ``[:esr, :capabilities, :denied]`` telemetry and
  # reply ``{:tool_result, req_id, %{"ok" => false, "error" =>
  # %{"type" => "unauthorized", ...}}}`` to the CC-side channel. No
  # directive is broadcast to the adapter.
  def handle_info(
        {:tool_invoke, req_id, tool, args, reply_pid, principal_id},
        %__MODULE__{} = state
      ) do
    workspace = Map.get(args, "workspace_name")
    required = "workspace:#{workspace || "*"}/#{tool}"

    if capability_granted?(principal_id, required) do
      # Emit a structured log line for _echo so the gate's L2 grep can match
      # "tool_invoke.*_echo.*req_id=.*args.nonce=..."
      if tool == "_echo" do
        nonce = Map.get(args, "nonce", "")
        Logger.info("tool_invoke _echo req_id=#{req_id} args.nonce=\"#{nonce}\" actor_id=#{state.actor_id}")
      end

      case build_emit_for_tool(tool, args, state) do
        {:ok, emit} ->
          {:ok, directive_id, new_state} = emit_and_track(emit, state)

          pending_tool_reqs =
            Map.put(new_state.pending_tool_reqs, directive_id, {req_id, reply_pid})

          {:noreply, %__MODULE__{new_state | pending_tool_reqs: pending_tool_reqs}}

        {:ok, :direct_ack, result} ->
          # Direct-ack tools (e.g. `session.signal_cleanup`) finish
          # synchronously inside build_emit_for_tool/3 — no adapter
          # directive, no pending_tool_reqs entry. Reply immediately
          # so the CC caller's tool_invoke round-trip completes.
          send(
            reply_pid,
            {:tool_result, req_id, Map.merge(%{"ok" => true}, result)}
          )

          {:noreply, state}

        {:error, reason} ->
          send(
            reply_pid,
            {:tool_result, req_id,
             %{
               "ok" => false,
               "error" => %{"type" => "invalid_args", "message" => reason}
             }}
          )

          {:noreply, state}
      end
    else
      :telemetry.execute(
        [:esr, :capabilities, :denied],
        %{count: 1},
        %{
          principal_id: principal_id,
          required_perm: required,
          lane: :B_tool_invoke,
          actor_id: state.actor_id,
          tool: tool
        }
      )

      # Match the real :tool_result reply shape (see the ack clause at
      # peer_server.ex and the build_emit_for_tool invalid_args branch
      # above) — CC reads the "error.type" field. "❌ 无权限..." user-
      # facing surfacing happens in Lane A (CAP-5); the CC-side MCP
      # bridge forwards this JSON verbatim to the caller.
      send(
        reply_pid,
        {:tool_result, req_id,
         %{
           "ok" => false,
           "error" => %{
             "type" => "unauthorized",
             "required_perm" => required
           }
         }}
      )

      {:noreply, state}
    end
  end

  # C4 — directive_ack for tool_invoke: push tool_result, drop both
  # pending maps. Guard ensures we match only ids that came from a
  # tool_invoke; other Emit acks fall through to the existing clause.
  def handle_info(
        {:directive_ack, %{"id" => id} = envelope},
        %__MODULE__{pending_tool_reqs: pending} = state
      )
      when is_map_key(pending, id) do
    {req_id, reply_pid} = Map.fetch!(pending, id)
    payload = envelope["payload"] || %{}

    result = %{
      "ok" => payload["ok"] == true,
      "data" => payload["result"],
      "error" => payload["error"]
    }

    send(reply_pid, {:tool_result, req_id, result})

    Phoenix.PubSub.unsubscribe(EsrWeb.PubSub, "directive_ack:" <> id)

    {:noreply,
     %__MODULE__{
       state
       | pending_tool_reqs: Map.delete(pending, id),
         pending_directives: Map.delete(state.pending_directives, id)
     }}
  end

  def handle_info({:directive_ack, %{"id" => id, "payload" => payload}}, %__MODULE__{} = state) do
    case Map.pop(state.pending_directives, id) do
      {nil, _} ->
        {:noreply, state}

      {_entry, remaining} ->
        Phoenix.PubSub.unsubscribe(EsrWeb.PubSub, "directive_ack:" <> id)
        emit_directive_outcome(state.actor_id, id, payload)
        {:noreply, %__MODULE__{state | pending_directives: remaining}}
    end
  end

  # Guarded deadline clause for tool_invoke ids — must come before the
  # catch-all directive_deadline clause below.
  def handle_info(
        {:directive_deadline, id},
        %__MODULE__{pending_tool_reqs: pending} = state
      )
      when is_map_key(pending, id) do
    {req_id, reply_pid} = Map.fetch!(pending, id)

    send(
      reply_pid,
      {:tool_result, req_id,
       %{
         "ok" => false,
         "error" => %{"type" => "timeout", "message" => "directive ack timeout"}
       }}
    )

    Phoenix.PubSub.unsubscribe(EsrWeb.PubSub, "directive_ack:" <> id)

    :telemetry.execute([:esr, :emit, :failed], %{}, %{
      actor_id: state.actor_id,
      directive_id: id,
      reason: :timeout
    })

    {:noreply,
     %__MODULE__{
       state
       | pending_tool_reqs: Map.delete(pending, id),
         pending_directives: Map.delete(state.pending_directives, id)
     }}
  end

  def handle_info({:directive_deadline, id}, %__MODULE__{} = state) do
    case Map.pop(state.pending_directives, id) do
      {nil, _} ->
        {:noreply, state}

      {_entry, remaining} ->
        Phoenix.PubSub.unsubscribe(EsrWeb.PubSub, "directive_ack:" <> id)

        :telemetry.execute([:esr, :emit, :failed], %{}, %{
          actor_id: state.actor_id,
          directive_id: id,
          reason: :timeout
        })

        {:noreply, %__MODULE__{state | pending_directives: remaining}}
    end
  end

  # init/1 sets trap_exit: true so terminate/2 fires on supervisor
  # shutdown (F14 stop-cascade telemetry). PeerServer doesn't link any
  # worker explicitly, so incoming {:EXIT, _, _} messages are stray —
  # swallow them to avoid FunctionClauseError crashes in handle_info/2
  # (reviewer S8).
  def handle_info({:EXIT, _from, _reason}, %__MODULE__{} = state) do
    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # Event invocation pipeline (F06)
  # ------------------------------------------------------------------

  defp invoke_handler(%__MODULE__{} = state, envelope, idempotency_key) do
    # The Python handler_worker looks up the handler fn in
    # HANDLER_REGISTRY keyed by ``<actor_type>.<handler_name>`` — we
    # register ``on_msg`` per-actor_type so the key is synthesised from
    # actor_type + "on_msg" at call time. PRD 05 names "on_msg" as the
    # sole v0.1 entry; future variants can thread the name through from
    # the pattern if needed.
    payload = %{
      "handler" => state.actor_type <> ".on_msg",
      "state" => state.state,
      "event" => Map.get(envelope, "payload", %{})
    }

    event_id = Map.get(envelope, "id", "")

    case call_with_retry(state, payload) do
      {:ok, new_state, actions} when is_map(new_state) and is_list(actions) ->
        :telemetry.execute([:esr, :handler, :invoked], %{}, %{
          actor_id: state.actor_id,
          event_id: event_id
        })

        # Spec §7.4: persist new_state BEFORE dispatching actions, so a
        # crash between the two never emits directives for a state the
        # system has no record of.
        state
        |> Map.put(:state, new_state)
        |> record_dedup(idempotency_key)
        |> persist_state()
        |> dispatch_actions(actions)

      {:error, {:retry_exhausted, reason}} ->
        :telemetry.execute([:esr, :handler, :retry_exhausted], %{}, %{
          actor_id: state.actor_id,
          event_id: event_id,
          reason: reason
        })

        Esr.DeadLetter.enqueue(Esr.DeadLetter, %{
          reason: :handler_retry_exhausted,
          source: state.actor_id,
          msg: envelope,
          metadata: %{handler_module: state.handler_module, last_error: reason}
        })

        state

      {:error, reason} ->
        # Non-retryable (deterministic handler error, e.g. invalid reply).
        :telemetry.execute([:esr, :handler, :error], %{}, %{
          actor_id: state.actor_id,
          event_id: event_id,
          reason: reason
        })

        state
    end
  end

  # PRD 01 F06 — at-least-once handler retry. Retry once on transient
  # errors (:handler_timeout, {:worker_crashed, _}); on second failure
  # signal {:retry_exhausted, reason} upstream so the caller can
  # dead-letter it.
  defp call_with_retry(%__MODULE__{} = state, payload) do
    handle_first_attempt(state, payload, call_handler(state, payload))
  end

  defp handle_first_attempt(_state, _payload, {:ok, _, _} = ok), do: ok

  defp handle_first_attempt(state, payload, {:error, reason}) do
    if retryable?(reason) do
      retry_once(state, payload)
    else
      {:error, reason}
    end
  end

  defp retry_once(state, payload) do
    case call_handler(state, payload) do
      {:ok, _, _} = ok -> ok
      {:error, reason} -> {:error, {:retry_exhausted, reason}}
    end
  end

  defp call_handler(state, payload) do
    HandlerRouter.call(state.handler_module, payload, state.handler_timeout)
  end

  # PRD F06 also lists {:worker_crashed, _} as retryable; that signal
  # arrives once F10 (HandlerRouter.Pool) lands and monitors worker
  # ports. Add the clause when the router starts emitting it.
  defp retryable?(:handler_timeout), do: true
  defp retryable?(_), do: false

  defp record_dedup(%__MODULE__{} = state, nil), do: state

  defp record_dedup(%__MODULE__{dedup_keys: keys, dedup_order: order} = state, key)
       when is_binary(key) do
    # PRD F05: bounded 1000-entry MapSet with FIFO eviction.
    new_order = :queue.in(key, order)
    new_keys = MapSet.put(keys, key)

    {final_keys, final_order} = evict_if_full(new_keys, new_order)

    %__MODULE__{state | dedup_keys: final_keys, dedup_order: final_order}
  end

  defp evict_if_full(keys, order) do
    if MapSet.size(keys) > @dedup_limit do
      {{:value, oldest}, trimmed_order} = :queue.out(order)
      {MapSet.delete(keys, oldest), trimmed_order}
    else
      {keys, order}
    end
  end

  defp persist_state(%__MODULE__{actor_id: actor_id, state: inner} = s) do
    PersistStore.put(@persist_table, actor_id, inner)
    s
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

  defp dispatch_actions(%__MODULE__{} = state, actions) do
    Enum.reduce(actions, state, &dispatch_action/2)
  end

  # v0.2 §3.3 — esr-channel is synthetic; short-circuit via SessionSocketRegistry.
  defp dispatch_action(
         %{"type" => "emit", "adapter" => "esr-channel"} = action,
         %__MODULE__{} = state
       ) do
    args = Map.get(action, "args", %{})
    session_id = Map.get(args, "session_id", "")

    envelope = %{
      "kind" => "notification",
      "source" => Map.get(args, "source", ""),
      "chat_id" => Map.get(args, "chat_id", ""),
      "message_id" => Map.get(args, "message_id", ""),
      "user" => Map.get(args, "user", ""),
      "content" => Map.get(args, "content", ""),
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :telemetry.execute([:esr, :emit, :dispatched], %{}, %{
      actor_id: state.actor_id,
      adapter: "esr-channel",
      action: "notify_session",
      session_id: session_id
    })

    case Esr.SessionSocketRegistry.notify_session(session_id, envelope) do
      :ok ->
        :ok

      {:error, reason} ->
        :telemetry.execute([:esr, :emit, :failed], %{}, %{
          actor_id: state.actor_id,
          adapter: "esr-channel",
          session_id: session_id,
          reason: reason
        })
    end

    state
  end

  defp dispatch_action(%{"type" => "emit"} = action, %__MODULE__{} = state) do
    adapter = action["adapter"]
    # Prefer the topic of a peer ALREADY bound to this adapter name —
    # otherwise the emitter (e.g. feishu_thread_proxy) is never joined
    # to a Phoenix channel, and broadcasts to adapter:<name>/<emitter>
    # would go to nobody. HubRegistry.list is tiny (bounded by peer
    # count), so the scan is cheap.
    prefix = "adapter:" <> adapter <> "/"

    topic =
      case Enum.find(Esr.AdapterHub.Registry.list(), fn {t, _actor_id} ->
             String.starts_with?(t, prefix)
           end) do
        {bound_topic, _actor_id} -> bound_topic
        nil -> prefix <> state.actor_id
      end

    id = "d-" <> Integer.to_string(System.unique_integer([:positive]))

    # Subscribe BEFORE broadcast so a fast ack lands in our mailbox.
    Phoenix.PubSub.subscribe(EsrWeb.PubSub, "directive_ack:" <> id)
    Process.send_after(self(), {:directive_deadline, id}, state.directive_timeout)

    envelope = %{
      "kind" => "directive",
      "id" => id,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "type" => "directive",
      "source" => "esr://localhost/actor/" <> state.actor_id,
      "payload" => %{
        "adapter" => adapter,
        "action" => action["action"],
        "args" => Map.get(action, "args", %{})
      }
    }

    # "envelope" event + kind-in-payload is the unified wire shape the
    # Python adapter_runner filters on (see comment on Instantiator).
    EsrWeb.Endpoint.broadcast(topic, "envelope", envelope)

    :telemetry.execute([:esr, :emit, :dispatched], %{}, %{
      actor_id: state.actor_id,
      adapter: adapter,
      action: action["action"],
      directive_id: id
    })

    %__MODULE__{state | pending_directives: Map.put(state.pending_directives, id, %{action: action})}
  end

  defp dispatch_action(%{"type" => "route", "target" => target, "msg" => msg}, %__MODULE__{} = state) do
    case Registry.lookup(Esr.PeerRegistry, target) do
      [{pid, _}] ->
        send(pid, {:inbound_event, %{"payload" => msg}})

      [] ->
        :telemetry.execute([:esr, :route, :target_missing], %{}, %{
          actor_id: state.actor_id,
          target: target
        })
    end

    state
  end

  defp dispatch_action(%{"type" => "invoke_command"} = action, %__MODULE__{} = state) do
    name = action["name"]
    params = Map.get(action, "params", %{})

    case TopoRegistry.get_artifact(name) do
      {:ok, artifact} ->
        # Instantiator.instantiate blocks up to directive_timeout per
        # init_directive node; run it in a fire-and-forget Task so the
        # PeerServer's mailbox stays responsive (reviewer S2/C5).
        actor_id = state.actor_id

        _ = Task.start(fn -> run_instantiation(artifact, params, actor_id) end)

      :error ->
        :telemetry.execute([:esr, :invoke_command, :unknown], %{}, %{
          actor_id: state.actor_id,
          name: name
        })
    end

    state
  end

  defp dispatch_action(unknown, %__MODULE__{} = state) do
    :telemetry.execute([:esr, :action, :unknown], %{}, %{
      actor_id: state.actor_id,
      action: unknown
    })

    state
  end

  defp run_instantiation(artifact, params, source_actor) do
    case TopoInstantiator.instantiate(artifact, params) do
      {:ok, _handle} ->
        :telemetry.execute([:esr, :topology, :activated], %{}, %{
          name: artifact["name"],
          params: params,
          invoked_by: source_actor
        })

      {:error, reason} ->
        :telemetry.execute([:esr, :topology, :failed], %{}, %{
          name: artifact["name"],
          params: params,
          invoked_by: source_actor,
          reason: reason
        })
    end
  end

  defp emit_directive_outcome(actor_id, id, %{"ok" => true}) do
    :telemetry.execute([:esr, :emit, :completed], %{}, %{
      actor_id: actor_id,
      directive_id: id
    })
  end

  defp emit_directive_outcome(actor_id, id, payload) do
    :telemetry.execute([:esr, :emit, :failed], %{}, %{
      actor_id: actor_id,
      directive_id: id,
      reason: payload
    })
  end

  defp build_emit_for_tool("reply", args, _state) do
    case args do
      %{"chat_id" => chat_id, "text" => text}
      when is_binary(chat_id) and is_binary(text) ->
        {:ok,
         %{
           "type" => "emit",
           "adapter" => "feishu",
           "action" => "send_message",
           "args" => %{"chat_id" => chat_id, "content" => text}
         }}

      _ ->
        {:error, "reply requires chat_id + text"}
    end
  end

  defp build_emit_for_tool("react", args, _state) do
    case args do
      %{"message_id" => mid, "emoji_type" => emoji} ->
        {:ok,
         %{
           "type" => "emit",
           "adapter" => "feishu",
           "action" => "react",
           "args" => %{"message_id" => mid, "emoji_type" => emoji}
         }}

      _ ->
        {:error, "react requires message_id + emoji_type"}
    end
  end

  defp build_emit_for_tool("send_file", args, _state) do
    case args do
      %{"chat_id" => cid, "file_path" => fp} ->
        {:ok,
         %{
           "type" => "emit",
           "adapter" => "feishu",
           "action" => "send_file",
           "args" => %{"chat_id" => cid, "file_path" => fp}
         }}

      _ ->
        {:error, "send_file requires chat_id + file_path"}
    end
  end

  defp build_emit_for_tool("_echo", args, %__MODULE__{state: thread_state}) do
    nonce = Map.get(args, "nonce", "")
    chat_id = Map.get(thread_state, "chat_id", "")

    if chat_id == "" do
      {:error, "_echo requires thread state.chat_id"}
    else
      build_emit_for_tool("reply", %{"chat_id" => chat_id, "text" => nonce}, nil)
    end
  end

  # DI-11 Task 24: route session cleanup signals from CC to the Admin
  # dispatcher. Returns `{:ok, :direct_ack, result}` — a distinct tag
  # from the usual `{:ok, emit}` path so `handle_info(:tool_invoke)`
  # skips the adapter broadcast and acks the CC caller immediately.
  # `send/2` is fire-and-forget: a missing Dispatcher (e.g. early boot)
  # must never block or crash the tool_invoke; the CC-side caller gets
  # the ack regardless. Task 25 adds matching `handle_info/2` on
  # `Esr.Admin.Dispatcher` — today its catch-all swallows the message.
  defp build_emit_for_tool("session.signal_cleanup", args, _state) do
    if pid = Process.whereis(Esr.Admin.Dispatcher) do
      send(
        pid,
        {:cleanup_signal, args["session_id"], args["status"], args["details"] || %{}}
      )
    end

    {:ok, :direct_ack, %{"acknowledged" => true}}
  end

  defp build_emit_for_tool(unknown, _args, _state),
    do: {:error, "unknown tool: #{unknown}"}

  # Same as the inline logic in the legacy emit dispatch_action clause,
  # but returns {:ok, directive_id, state'} so handle_info(:tool_invoke)
  # can correlate the ack back to the req_id.
  defp emit_and_track(%{"adapter" => adapter} = action, %__MODULE__{} = state) do
    id = "d-" <> Integer.to_string(System.unique_integer([:positive]))
    topic = emit_topic_for(adapter, state.actor_id)

    Phoenix.PubSub.subscribe(EsrWeb.PubSub, "directive_ack:" <> id)
    Process.send_after(self(), {:directive_deadline, id}, state.directive_timeout)

    envelope = %{
      "kind" => "directive",
      "id" => id,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "type" => "directive",
      "source" => "esr://localhost/actor/" <> state.actor_id,
      "payload" => %{
        "adapter" => adapter,
        "action" => action["action"],
        "args" => Map.get(action, "args", %{})
      }
    }

    EsrWeb.Endpoint.broadcast(topic, "envelope", envelope)

    :telemetry.execute([:esr, :emit, :dispatched], %{}, %{
      actor_id: state.actor_id,
      adapter: adapter,
      action: action["action"],
      directive_id: id
    })

    {:ok, id,
     %__MODULE__{
       state
       | pending_directives: Map.put(state.pending_directives, id, %{action: action})
     }}
  end

  defp emit_topic_for(adapter, fallback_actor) do
    prefix = "adapter:" <> adapter <> "/"

    case Enum.find(Esr.AdapterHub.Registry.list(), fn {t, _} ->
           String.starts_with?(t, prefix)
         end) do
      {bound_topic, _} -> bound_topic
      nil -> prefix <> fallback_actor
    end
  end

  # --------------------------------------------------------------
  # Lane B capability check helpers (CAP-4)
  # --------------------------------------------------------------

  # Esr.Capabilities.has?/2 guards on is_binary(principal_id). Tests
  # and internal routes (`route` action at peer_server.ex line ~618)
  # can legitimately omit principal_id — treat anything non-binary as
  # "no grant" so the check always returns a boolean and the deny
  # path records the absent principal clearly.
  defp capability_granted?(principal_id, required)
       when is_binary(principal_id) and is_binary(required) do
    Esr.Capabilities.has?(principal_id, required)
  end

  defp capability_granted?(_principal_id, _required), do: false

  # Event-type → permission-name mapping for Lane B inbound enforcement.
  # `msg_received` maps to `msg.send` because receiving an inbound
  # message implies the principal may produce a handler-driven
  # response (spec §7.2). Unknown event types fall through to a
  # literal permission name so future event types default-deny unless
  # an operator explicitly grants them.
  defp permission_for_event("msg_received"), do: "msg.send"
  defp permission_for_event(other) when is_binary(other), do: other
  defp permission_for_event(_), do: "unknown"

  if Mix.env() == :test do
    @doc false
    def dispatch_action_for_test(action, state), do: dispatch_action(action, state)

    @doc false
    def invoke_tool_for_test(%__MODULE__{} = state, tool, args) do
      case build_emit_for_tool(tool, args, state) do
        {:ok, :direct_ack, result} ->
          Map.merge(%{"ok" => true}, result)

        {:ok, _emit} ->
          %{"ok" => true}

        {:error, reason} ->
          %{
            "ok" => false,
            "error" => %{"type" => "invalid_args", "message" => reason}
          }
      end
    end
  end
end

defmodule Esr.Entity.Server do
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

  Every Entity.Server is registered under its `actor_id` in
  `Esr.Entity.Registry` via `{:via, Registry, ...}`; telemetry
  `[:esr, :actor, :spawned]` fires in init/1.
  """

  @behaviour Esr.Role.State

  use GenServer
  @behaviour Esr.Handler
  require Logger

  alias Esr.HandlerRouter
  alias Esr.Persistence.Ets, as: PersistStore

  @doc """
  Built-in MCP tool names exposed by `build_emit_for_tool/3`
  (see `lib/esr/peer_server.ex` §"build_emit_for_tool" clauses).
  CAP-4 derives required permissions as `workspace:<ws>/<tool_name>`,
  so these four names must be registered in `Esr.Permissions.Registry`
  at boot or every tool_invoke would be denied.
  """
  @impl Esr.Handler
  # PR-9 T5 D4: `react` is no longer a CC-scoped MCP tool. It is
  # emitted by FeishuChatProxy on successful delivery of an inbound
  # message (as a delivery ACK) and un-reacted when CC's reply lands.
  # The permission name is gone from the CC-facing allowlist; the
  # underlying adapter-side action shape (`react` / `un_react`) stays
  # stable since the FeishuAppAdapter still dispatches them.
  def permissions, do: ["reply", "send_file", "_echo", "session.signal_cleanup"]

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

  @doc false
  # D2 test hook — exercises the three private emit builders without
  # standing up a live GenServer. Signature identical to the private
  # function; callers construct a fake %__MODULE__{} struct.
  def build_emit_for_tool_for_test(tool, args, state) do
    build_emit_for_tool(tool, args, state)
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

  defp via(actor_id), do: {:via, Registry, {Esr.Entity.Registry, actor_id}}

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
    # Esr.Entities.FeishuChatProxy's terminate/2 in PR-3 when the actor_type
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
    # PR-21x: cap check + telemetry + deny-DM dispatch are owned by
    # `Esr.Entities.CapGuard.check_inbound/3`. Entity.Server keeps the
    # handler-invocation hot path; the gate is one call away.
    workspace = envelope["workspace_name"]
    event_type = get_in(envelope, ["payload", "event_type"])
    required = "workspace:#{workspace || "*"}/#{permission_for_event(event_type)}"

    case Esr.Entities.CapGuard.check_inbound(envelope, required, state.actor_id) do
      :granted ->
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

      :denied ->
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

    # PR-F 2026-04-28: `describe_topology` returns non-secret yaml
    # metadata (operator-readable workspace + 1-hop neighbour info).
    # Per Q6 grill decision (Lane A/B audit-table reasoning), no cap
    # gate — the existing Lane B inbound gate is the single
    # enforcement point. Skip the workspace:<ws>/<tool> check here
    # so the tool is callable without operators wiring up
    # `workspace:<ws>/describe_topology` for every principal.
    if tool == "describe_topology" or capability_granted?(principal_id, required) do
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
  # shutdown (F14 stop-cascade telemetry). Entity.Server doesn't link any
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

  # v0.2 §3.3 — esr-channel is synthetic; short-circuit via AdapterSocketRegistry.
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

    case Esr.AdapterSocketRegistry.notify_session(session_id, envelope) do
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
    # Post-P2-16: AdapterHub.Registry is gone; fall back to the
    # deterministic "adapter:<name>/<self.actor_id>" shape. Python
    # adapters subscribed to any adapter:<name>/* topic still receive
    # the broadcast because Phoenix PubSub is topic-matched. PR-3's
    # Scope.Router + Entity.Factory replace this legacy lane outright.
    prefix = "adapter:" <> adapter <> "/"
    topic = prefix <> state.actor_id

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

  # P3-16: `route` action deleted. Spec §2.9 removes cross-esrd
  # routing — directive-returning handlers now flow through
  # peer chains, not a Entity.Registry lookup.

  defp dispatch_action(unknown, %__MODULE__{} = state) do
    :telemetry.execute([:esr, :action, :unknown], %{}, %{
      actor_id: state.actor_id,
      action: unknown
    })

    state
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

  # D2: read the session's bound channel adapter from the thread-state
  # map. D1 seeds state["channel_adapter"] in FeishuChatProxy.init/1
  # (and downstream peers copy it forward). Missing slot → "feishu"
  # fallback (§4.2 deprecated — removed once seeded path is live per
  # spec §14 item 2).
  defp session_channel_adapter(%__MODULE__{state: thread_state})
       when is_map(thread_state) do
    Map.get(thread_state, "channel_adapter", "feishu")
  end

  defp session_channel_adapter(_), do: "feishu"

  defp build_emit_for_tool("reply", args, state) do
    case args do
      %{"chat_id" => chat_id, "text" => text}
      when is_binary(chat_id) and is_binary(text) ->
        # PR-9 T5c: `reply_to_message_id` is optional. When present,
        # include it in the emit args so downstream consumers
        # (FeishuChatProxy in T5c's un_react path) can correlate the
        # reply with the inbound message to un-react. Absent → emit
        # shape identical to pre-T5 (backward compat per D4).
        base_args = %{"chat_id" => chat_id, "content" => text}

        args_out =
          case Map.get(args, "reply_to_message_id") do
            mid when is_binary(mid) and mid != "" ->
              Map.put(base_args, "reply_to_message_id", mid)

            _ ->
              base_args
          end

        {:ok,
         %{
           "type" => "emit",
           "adapter" => session_channel_adapter(state),
           "action" => "send_message",
           "args" => args_out
         }}

      _ ->
        {:error, "reply requires chat_id + text"}
    end
  end

  defp build_emit_for_tool("send_file", args, state) do
    case args do
      %{"chat_id" => cid, "file_path" => fp} when is_binary(fp) ->
        case File.read(fp) do
          {:ok, bytes} ->
            {:ok,
             %{
               "type" => "emit",
               "adapter" => session_channel_adapter(state),
               "action" => "send_file",
               "args" => %{
                 "chat_id" => cid,
                 "file_name" => Path.basename(fp),
                 "content_b64" => Base.encode64(bytes),
                 "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
               }
             }}

          {:error, reason} ->
            {:error, "send_file cannot read #{fp}: #{inspect(reason)}"}
        end

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
  # PR-F 2026-04-28: business-topology MCP tool. Reads workspaces.yaml
  # data from `Esr.Workspaces.Registry`, filters operational fields
  # (cwd, env, start_cmd) out, expands `workspace:<name>` neighbour
  # entries into a `neighbor_workspaces` array. cc_mcp's tool handler
  # injects `workspace_name` from the `ESR_WORKSPACE` env var so the
  # LLM-facing tool API stays parameter-less.
  #
  # Returns `{:ok, :direct_ack, %{"data" => %{...}}}` — synchronous,
  # no adapter directive emitted.
  defp build_emit_for_tool("describe_topology", args, _state) do
    case Map.get(args, "workspace_name") do
      ws_name when is_binary(ws_name) and ws_name != "" ->
        case Esr.Workspaces.Registry.get(ws_name) do
          {:ok, ws} ->
            neighbours = resolve_neighbour_workspaces_for_describe(ws)

            data = %{
              "current_workspace" => filter_workspace_for_describe(ws),
              "neighbor_workspaces" =>
                Enum.map(neighbours, &filter_workspace_for_describe/1)
            }

            {:ok, :direct_ack, %{"data" => data}}

          :error ->
            {:error, "unknown_workspace: #{ws_name}"}
        end

      _ ->
        {:error, "describe_topology requires workspace_name"}
    end
  end

  # PR-21z 2026-04-30 — security boundary: this is the ONLY function
  # that decides what `describe_topology` exposes to the LLM. Build it
  # as an explicit allowlist (NOT a denylist on the struct), so adding
  # a new field to `%Workspace{}` doesn't accidentally leak it.
  #
  # **Excluded by design:**
  #   - `owner` (esr-username — sensitive once paired with `users.yaml`'s
  #     feishu_ids; describe_topology is principal-agnostic on purpose)
  #   - `start_cmd` (operator config; could leak shell paths / args)
  #   - `env` (workspace env block — may carry secrets)
  #
  # The chats sub-map uses its own allowlist for the same reason.
  # **Never expose `users.yaml` data here** — feishu open_ids / esr-
  # username pairings are out-of-band identity material that the LLM
  # has no business reading. Default-deny: if you need a new field,
  # add it AND a regression test in `peer_server_describe_topology_test.exs`.
  defp filter_workspace_for_describe(%Esr.Workspaces.Registry.Workspace{} = ws) do
    %{
      "name" => ws.name,
      "role" => ws.role || "dev",
      "chats" =>
        Enum.map(ws.chats || [], fn chat ->
          if is_map(chat) do
            Map.take(chat, ["chat_id", "app_id", "kind", "name", "metadata"])
          else
            %{}
          end
        end),
      "neighbors_declared" => ws.neighbors || [],
      "metadata" => ws.metadata || %{}
    }
  end

  defp resolve_neighbour_workspaces_for_describe(%Esr.Workspaces.Registry.Workspace{
         neighbors: neighbours
       }) do
    neighbours
    |> Enum.flat_map(fn entry ->
      case String.split(entry || "", ":", parts: 2) do
        ["workspace", name] ->
          case Esr.Workspaces.Registry.get(name) do
            {:ok, ws} -> [ws]
            :error -> []
          end

        _ ->
          []
      end
    end)
  end

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
    # Post-P2-16: AdapterHub.Registry is gone; fall back to the
    # deterministic "adapter:<name>/<fallback_actor>" shape. Legacy
    # tool-invoke path; replaced outright by the new peer chain in PR-3.
    "adapter:" <> adapter <> "/" <> fallback_actor
  end

  # --------------------------------------------------------------
  # Lane B capability check helpers (CAP-4)
  # --------------------------------------------------------------

  # PR-21x: Lane B deny-DM dispatch + `@feishu_source_re` extracted into
  # `Esr.Entities.CapGuard.check_inbound/3`. The cap check, telemetry, and
  # rate-limited DM all live there now — this module just decides
  # `:granted` vs `:denied` via that one call.

  # Esr.Capabilities.has?/2 guards on is_binary(principal_id). Tests
  # and internal routes (`route` action at peer_server.ex line ~618)
  # can legitimately omit principal_id — treat anything non-binary as
  # "no grant" so the check always returns a boolean and the deny
  # path records the absent principal clearly.
  #
  # P3-3a: this helper still reads the global `Esr.Capabilities.has?/2`
  # rather than `Esr.Scope.Process.has?/2`. The legacy peer_server
  # module is slated to die in P3-16 (its CC/tool-invoke paths migrate
  # to per-session peer modules which are spawned through
  # `Entity.Factory.spawn_peer/5` and receive a `session_process_pid` in
  # their `proxy_ctx`). Leaving the global read in place here keeps the
  # legacy data plane working during the cutover; migration happens by
  # deletion, not refactor.
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

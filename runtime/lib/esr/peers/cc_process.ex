defmodule Esr.Peers.CCProcess do
  @moduledoc """
  Per-Session `Peer.Stateful` holding CC business state. Invokes Python
  handler code via `Esr.HandlerRouter.call/3` on upstream messages and
  translates handler actions into downstream messages for the
  `TmuxProcess` neighbor (`:send_input`) or upward replies to the
  upstream chat proxy via `CCProxy` (`:reply`).

  State:

    * `:session_id` — session this peer belongs to (spec §3.1)
    * `:handler_module` — the Python handler module string (e.g.
      `"cc_adapter_runner"`) passed verbatim as the first argument to
      `HandlerRouter.call/3`
    * `:cc_state` — the handler's opaque state blob, threaded through
      each invocation (`payload["state"]` in, `new_state` out)
    * `:neighbors` — keyword: `:tmux_process`, `:cc_proxy`
    * `:proxy_ctx` — shared context snapshot (principal_id, etc.) used
      by downstream Peer.Proxy ctx hooks
    * `:handler_override` — optional 3-arity fun for tests to stub the
      HandlerRouter round-trip without a running Phoenix worker
      channel; set via `put_handler_override/2`

  Peer.Stateful protocol (spec §3.1):

    * `handle_upstream({:text, bytes}, state)` — from `CCProxy`; invoke
      handler, dispatch resulting actions
    * `handle_upstream({:tmux_output, bytes}, state)` — from
      `TmuxProcess`; invoke handler, dispatch resulting actions
    * `handle_downstream(_, state)` — no-op in PR-3 (the upward path is
      handled via direct dispatch of `:reply` actions to the `cc_proxy`
      neighbor; no downstream message arrives here today)

  Spec §4.1 CCProcess card, §5.1 data flow; expansion P3-2.
  """
  use Esr.Peer.Stateful
  use GenServer
  require Logger

  @default_timeout 5_000

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  # start_link/1 inherits the dual-shape (map | keyword) default from
  # Esr.Peer.Stateful (PR-6 B1). All current callers pass %{}.

  @impl Esr.Peer
  def spawn_args(params) do
    %{handler_module: Esr.Peer.get_param(params, :handler_module) || "cc_adapter_runner"}
  end

  @doc """
  Installs a 3-arity fun `(handler_module, payload, timeout)` that
  replaces the real `HandlerRouter.call/3` call inside this peer. Used
  by tests to stub the handler round-trip deterministically. The
  override lives in the peer's own process state, so it is scoped to
  this pid only and does not leak across tests.
  """
  @spec put_handler_override(pid(), (String.t(), map(), pos_integer() -> term())) :: :ok
  def put_handler_override(pid, fun) when is_pid(pid) and is_function(fun, 3) do
    GenServer.call(pid, {:put_handler_override, fun})
  end

  # ------------------------------------------------------------------
  # Peer.Stateful callbacks
  # ------------------------------------------------------------------

  @impl GenServer
  def init(args) do
    sid = Map.fetch!(args, :session_id)

    # PR-9 T12-comms-3c: subscribe to the cc_mcp-ready control topic so
    # we can flush buffered send_input notifications as soon as cc_mcp
    # joins cli:channel/<sid>. Phoenix.PubSub drops broadcasts with no
    # subscribers, so dispatch_action(send_input) fired during the
    # ~10s window between pipeline spawn and cc_mcp join would be lost
    # — scenario 01's first user inbound was vanishing this way.
    # See docs/notes/cc-mcp-pubsub-race.md.
    _ = maybe_subscribe("cc_mcp_ready/" <> sid)

    {:ok,
     %{
       session_id: sid,
       handler_module: Map.fetch!(args, :handler_module),
       cc_state: Map.get(args, :initial_state, %{}),
       neighbors: Map.get(args, :neighbors, []),
       proxy_ctx: Map.get(args, :proxy_ctx, %{}),
       handler_override: nil,
       pending_notifications: [],
       cc_mcp_ready: false
     }}
  end

  # Phoenix.PubSub isn't running in every unit-test setup (some call
  # init/1 directly without booting EsrWeb.PubSub). Swallow the
  # :not_running-style errors so tests keep working.
  defp maybe_subscribe(topic) do
    case Process.whereis(EsrWeb.PubSub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.subscribe(EsrWeb.PubSub, topic)
    end
  end

  @impl Esr.Peer.Stateful
  def handle_upstream({:text, _bytes} = msg, state), do: invoke_and_dispatch(msg, state)
  # PR-9 T11b.6a: FCP now sends `{:text, text, meta}` (3-tuple) carrying
  # message_id/sender_id/thread_id so T11b.6's pubsub notification can
  # populate the `<channel>` meta attributes. Legacy 2-tuple still accepted
  # for backward compat with unit tests that haven't migrated yet.
  def handle_upstream({:text, _bytes, _meta} = msg, state), do: invoke_and_dispatch(msg, state)

  # PR-9 T11b.8 e2e RCA: tmux_output bytes (CC's TUI chrome — ANSI
  # escapes, box drawing, partial-UTF8 bursts when reads split a
  # multibyte char) should NOT be invoked as a handler event. Jason
  # encoding crashed on truncated UTF-8 sequences, killing CCProcess.
  # Post-T11b the conversation path runs through the MCP channel
  # (cli:channel/<sid>), not tmux stdout capture — so tmux_output is
  # diagnostic-only. Drop at this layer; future diagnostic handlers
  # can subscribe to the raw :tmux_event topic separately.
  def handle_upstream({:tmux_output, _bytes}, state),
    do: {:drop, :tmux_diagnostic, state}

  def handle_upstream(_other, state), do: {:drop, :unknown_upstream, state}

  # handle_downstream/2 inherits the no-op `{:forward, [], state}` default
  # from Esr.Peer.Stateful (PR-6 B1). PR-3 did not wire a downstream
  # message through here — upward `:reply` dispatch goes direct to the
  # cc_proxy neighbor.

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl GenServer
  def handle_call({:put_handler_override, fun}, _from, state) do
    {:reply, :ok, %{state | handler_override: fun}}
  end

  @impl GenServer
  def handle_info({:text, _} = msg, state),
    do: Esr.Peer.Stateful.dispatch_upstream(msg, state, __MODULE__)

  def handle_info({:text, _, _meta} = msg, state),
    do: Esr.Peer.Stateful.dispatch_upstream(msg, state, __MODULE__)

  # T11b.8: tmux_output is diagnostic only — drop silently at the
  # GenServer boundary too (mirrors the handle_upstream clause above).
  def handle_info({:tmux_output, _}, state), do: {:noreply, state}

  # T12-comms-3c: ChannelChannel's join-for-this-session broadcasts
  # {:cc_mcp_ready, session_id} on the "cc_mcp_ready/<sid>" topic.
  # When we receive it, flush every buffered send_input envelope that
  # couldn't broadcast earlier (no subscribers) and flip the state
  # flag so subsequent send_input actions broadcast immediately.
  def handle_info({:cc_mcp_ready, sid}, %{session_id: sid} = state) do
    for envelope <- state.pending_notifications do
      broadcast_notification(sid, envelope)
    end

    {:noreply, %{state | pending_notifications: [], cc_mcp_ready: true}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp invoke_and_dispatch(event, state) do
    # PR-9 T11b.6: capture the upstream meta into cc_state so dispatch
    # actions (SendInput / Reply) can reference per-event attribution
    # (message_id, sender_id, thread_id) when building their envelopes.
    # Handler implementations don't need to echo them back.
    state = stash_upstream_meta(state, event)

    payload = %{
      "handler" => state.handler_module <> ".on_msg",
      "state" => state.cc_state,
      "event" => event_to_map(event)
    }

    case call_handler(state, payload, @default_timeout) do
      {:ok, new_state, actions} when is_map(new_state) and is_list(actions) ->
        dispatched_state = dispatch_actions(actions, state)
        {:forward, [], %{dispatched_state | cc_state: new_state}}

      {:error, :handler_timeout} ->
        Logger.warning(
          "cc_process: handler timeout session_id=#{state.session_id}"
        )

        :telemetry.execute([:esr, :cc_process, :handler_timeout], %{}, %{
          session_id: state.session_id
        })

        {:drop, :handler_timeout, state}

      {:error, other} ->
        Logger.warning(
          "cc_process: handler error #{inspect(other)} session_id=#{state.session_id}"
        )

        :telemetry.execute([:esr, :cc_process, :handler_error], %{}, %{
          session_id: state.session_id,
          reason: other
        })

        {:drop, :handler_error, state}
    end
  end

  defp call_handler(%{handler_override: fun}, payload, timeout) when is_function(fun, 3) do
    fun.(payload["handler"] |> strip_fn_suffix(), payload, timeout)
  end

  defp call_handler(state, payload, timeout) do
    # P3-10: Application-env override reaches across process boundaries
    # for integration tests that spawn CCProcess indirectly (via
    # SessionRouter/PeerFactory) and therefore don't have the pid handy
    # at start to call `put_handler_override/2`. The override, when set,
    # takes precedence over the real HandlerRouter round-trip. Scoped to
    # `Mix.env() == :test`-style usage; prod leaves the env unset.
    case Application.get_env(:esr, :handler_module_override) do
      {:test_fun, fun} when is_function(fun, 3) ->
        fun.(strip_fn_suffix(payload["handler"]), payload, timeout)

      _ ->
        Esr.HandlerRouter.call(state.handler_module, payload, timeout)
    end
  end

  # The payload threads the handler module as "<mod>.on_msg" (matching
  # PeerServer's invoke_handler convention), but the override callback
  # receives the bare module string — strip the "on_msg" suffix so test
  # stubs can assert on the canonical module name.
  defp strip_fn_suffix(handler_fqn) do
    case String.split(handler_fqn, ".", parts: 2) do
      [mod, _fn] -> mod
      [mod] -> mod
    end
  end

  defp dispatch_actions(actions, state) do
    # Thread state through so send_input can buffer notifications in
    # state.pending_notifications when cc_mcp hasn't joined yet.
    Enum.reduce(actions, state, fn action, acc ->
      case dispatch_action(action, acc) do
        {:buffered, new_state} -> new_state
        _ -> acc
      end
    end)
  end

  # PR-9 T11b.6: SendInput now broadcasts a `notifications/claude/channel`-shaped
  # envelope on Phoenix topic `cli:channel/<session_id>` instead of sending
  # `{:send_input, text}` to the tmux pane's stdin. User principle
  # (2026-04-24): CC reply path goes through esr-channel, not tmux stdout
  # capture — symmetrically, CC inbound arrives via the MCP channel
  # notification stream, not tmux stdin. cc_mcp's `_handle_inbound` receives
  # this envelope and injects the `<channel>` tag into CC's context.
  #
  # Envelope shape matches cc_mcp channel.py's consumer: `kind: "notification"`
  # + `source`, `chat_id`, `message_id`, `user`, `ts`, `thread_id`, `content`.
  # cc_mcp's inbound handler re-maps these into the `notifications/claude/channel`
  # params/meta shape CC's channels listener expects.
  defp dispatch_action(%{"type" => "send_input", "text" => text}, state) do
    envelope = build_channel_notification(state, text)

    # PR-9 T12-comms-3c: if cc_mcp hasn't joined cli:channel/<sid> yet,
    # buffer the envelope and let handle_info({:cc_mcp_ready, sid}, …)
    # flush it on join. Phoenix.PubSub drops broadcasts with zero
    # subscribers — and cc_mcp takes ~10s to boot under claude for
    # a first-inbound auto-create. See docs/notes/cc-mcp-pubsub-race.md.
    if state.cc_mcp_ready do
      broadcast_notification(state.session_id, envelope)
      {:buffered, state}
    else
      {:buffered, %{state | pending_notifications: state.pending_notifications ++ [envelope]}}
    end
  end

  defp dispatch_action(%{"type" => "reply", "text" => text} = action, state) do
    # PR-9 T5c: propagate the optional `reply_to_message_id` so
    # FeishuChatProxy can un-react the referenced inbound message before
    # forwarding the reply. When absent (legacy CC handler, or reply
    # unrelated to a specific inbound) the 2-tuple {:reply, text} is
    # preserved for backward compat.
    msg =
      case Map.get(action, "reply_to_message_id") do
        mid when is_binary(mid) and mid != "" ->
          {:reply, text, %{reply_to_message_id: mid}}

        _ ->
          {:reply, text}
      end

    # Prefer the feishu_chat_proxy neighbor when it's available — that's
    # the production upstream-reply target in PR-9 T5's topology (the
    # proxy converts :reply into `{:outbound, ...}` to feishu_app_proxy).
    # Fall back to cc_proxy for unit tests that inject a raw test pid.
    target_pid =
      case Keyword.get(state.neighbors, :feishu_chat_proxy) do
        pid when is_pid(pid) -> pid
        _ -> Keyword.get(state.neighbors, :cc_proxy)
      end

    case target_pid do
      pid when is_pid(pid) ->
        send(pid, msg)

      _ ->
        Logger.warning(
          "cc_process: :reply with no feishu_chat_proxy or cc_proxy neighbor " <>
            "session_id=#{state.session_id}"
        )
    end
  end

  defp dispatch_action(unknown, state) do
    :telemetry.execute([:esr, :cc_process, :unknown_action], %{}, %{
      session_id: state.session_id,
      action: unknown
    })
  end

  # `{:notification, envelope}` matches the existing admin-side
  # precedent in `Esr.Admin.Commands.Session.BranchEnd` — ChannelChannel
  # handle_info/2 routes both `{:push_envelope, _}` and
  # `{:notification, _}` identically, and sticking with the admin
  # convention keeps the ops + logs consistent.
  defp broadcast_notification(session_id, envelope) do
    Phoenix.PubSub.broadcast(
      EsrWeb.PubSub,
      "cli:channel/" <> session_id,
      {:notification, envelope}
    )

    :ok
  end

  defp build_channel_notification(state, text) do
    ctx = state.proxy_ctx || %{}
    last = Map.get(state, :last_meta, %{})

    %{
      "kind" => "notification",
      "source" => Map.get(ctx, "channel_adapter") || "feishu",
      # T12-comms-3d: prefer the per-event chat_id from FCP's meta — it's
      # authoritative for this specific inbound. Fall back to proxy_ctx
      # only for legacy callers that hadn't threaded it through yet.
      "chat_id" =>
        Map.get(last, :chat_id) || Map.get(ctx, :chat_id) || Map.get(ctx, "chat_id") || "",
      "thread_id" =>
        Map.get(last, :thread_id) || Map.get(ctx, :thread_id) || Map.get(ctx, "thread_id") || "",
      "message_id" => Map.get(last, :message_id) || "",
      "user" => Map.get(last, :sender_id) || "",
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "content" => text
    }
  end

  # PR-9 T11b.6: pull message_id/sender_id/thread_id off the upstream
  # 3-tuple `{:text, text, meta}` and stash in state so dispatch_action
  # builds the notification envelope with real attribution instead of
  # empty strings.
  defp stash_upstream_meta(state, {:text, _bytes, meta}) when is_map(meta) do
    Map.put(state, :last_meta, meta)
  end

  defp stash_upstream_meta(state, _other), do: state

  # Handler-side contract (py/src/esr/ipc/handler_worker.py process_handler_call):
  # the event dict must carry `event_type` + `args`. Earlier versions of this
  # module emitted `%{kind, text}` which handler_worker rejected as
  # MalformedEnvelope('event_type'). PR-9 T11a aligns the shapes.
  #
  # T11b.6a: 3-tuple `{:text, bytes, meta}` carries upstream
  # message_id/sender_id/thread_id so the handler (and downstream
  # SendInput/Reply actions in T11b.6) has real attribution.
  defp event_to_map({:text, bytes}),
    do: %{"event_type" => "text", "args" => %{"text" => bytes}}

  defp event_to_map({:text, bytes, meta}) when is_map(meta),
    do: %{
      "event_type" => "text",
      "args" =>
        %{"text" => bytes}
        |> Map.merge(
          meta
          |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
          |> Enum.map(fn {k, v} -> {Atom.to_string(k), v} end)
          |> Map.new()
        )
    }

  defp event_to_map({:tmux_output, bytes}),
    do: %{"event_type" => "tmux_output", "args" => %{"bytes" => bytes}}
end

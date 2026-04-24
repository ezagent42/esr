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
    {:ok,
     %{
       session_id: Map.fetch!(args, :session_id),
       handler_module: Map.fetch!(args, :handler_module),
       cc_state: Map.get(args, :initial_state, %{}),
       neighbors: Map.get(args, :neighbors, []),
       proxy_ctx: Map.get(args, :proxy_ctx, %{}),
       handler_override: nil
     }}
  end

  @impl Esr.Peer.Stateful
  def handle_upstream({:text, _bytes} = msg, state), do: invoke_and_dispatch(msg, state)
  def handle_upstream({:tmux_output, _bytes} = msg, state), do: invoke_and_dispatch(msg, state)
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

  def handle_info({:tmux_output, _} = msg, state),
    do: Esr.Peer.Stateful.dispatch_upstream(msg, state, __MODULE__)

  def handle_info(_other, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp invoke_and_dispatch(event, state) do
    payload = %{
      "handler" => state.handler_module <> ".on_msg",
      "state" => state.cc_state,
      "event" => event_to_map(event)
    }

    case call_handler(state, payload, @default_timeout) do
      {:ok, new_state, actions} when is_map(new_state) and is_list(actions) ->
        dispatch_actions(actions, state)
        {:forward, [], %{state | cc_state: new_state}}

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
    Enum.each(actions, &dispatch_action(&1, state))
  end

  defp dispatch_action(%{"type" => "send_input", "text" => text}, state) do
    case Keyword.get(state.neighbors, :tmux_process) do
      pid when is_pid(pid) ->
        send(pid, {:send_input, text})

      _ ->
        Logger.warning(
          "cc_process: :send_input with no tmux_process neighbor " <>
            "session_id=#{state.session_id}"
        )
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

  # Handler-side contract (py/src/esr/ipc/handler_worker.py process_handler_call):
  # the event dict must carry `event_type` + `args`. Earlier versions of this
  # module emitted `%{kind, text}` which handler_worker rejected as
  # MalformedEnvelope('event_type'). PR-9 T11a aligns the shapes.
  defp event_to_map({:text, bytes}),
    do: %{"event_type" => "text", "args" => %{"text" => bytes}}

  defp event_to_map({:tmux_output, bytes}),
    do: %{"event_type" => "tmux_output", "args" => %{"bytes" => bytes}}
end

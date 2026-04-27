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

    proxy_ctx = Map.get(args, :proxy_ctx, %{})

    # PR-C C6 (spec §7 hot-reload, eager-add): subscribe to the
    # per-workspace topology PubSub topic so newly-declared neighbours
    # in workspaces.yaml flow into reachable_set without restarting
    # the session. Per-workspace scoping keeps cross-workspace traffic
    # off this peer's mailbox.
    workspace_name = Map.get(proxy_ctx, :workspace_name) || Map.get(proxy_ctx, "workspace_name")

    if is_binary(workspace_name) and workspace_name != "" do
      _ = maybe_subscribe("topology:" <> workspace_name)
    end

    # PR-C C4 (2026-04-27 actor-topology-routing §5.2): seed the BGP
    # reachable_set from yaml topology + own chat + adapter URI. The
    # set grows when handle_upstream sees inbound URIs in `meta.source`
    # / `meta.principal_id` (learn_uris/2 below). Empty fallback when
    # workspace_name/chat_id aren't yet threaded into proxy_ctx —
    # learning still works, the prompt just won't expose neighbours
    # until the topology yaml + workspace mapping land.
    initial_reachable = build_initial_reachable_set(proxy_ctx)

    {:ok,
     %{
       session_id: sid,
       handler_module: Map.fetch!(args, :handler_module),
       cc_state: Map.get(args, :initial_state, %{}),
       neighbors: Map.get(args, :neighbors, []),
       proxy_ctx: proxy_ctx,
       handler_override: nil,
       pending_notifications: [],
       cc_mcp_ready: false,
       reachable_set: initial_reachable
     }}
  end

  defp build_initial_reachable_set(ctx) do
    workspace_name = Map.get(ctx, :workspace_name) || Map.get(ctx, "workspace_name")
    chat_id = Map.get(ctx, :chat_id) || Map.get(ctx, "chat_id")
    app_id = Map.get(ctx, :app_id) || Map.get(ctx, "app_id")

    chat_uri =
      if is_binary(workspace_name) and is_binary(chat_id) and chat_id != "" do
        Esr.Topology.chat_uri(workspace_name, chat_id)
      end

    adapter_uri =
      if is_binary(app_id) and app_id != "" do
        Esr.Topology.adapter_uri("feishu", app_id)
      end

    cond do
      is_binary(workspace_name) and not is_nil(chat_uri) ->
        Esr.Topology.initial_seed(workspace_name, chat_uri, adapter_uri)

      true ->
        # No workspace context yet — start empty; learning will fill
        # in as inbound `meta.source` URIs arrive.
        MapSet.new()
    end
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
    # pending_notifications was prepended (O(1)); reverse to preserve
    # the original `send_input` order on flush.
    for envelope <- Enum.reverse(state.pending_notifications) do
      broadcast_notification(sid, envelope)
    end

    {:noreply, %{state | pending_notifications: [], cc_mcp_ready: true}}
  end

  # PR-C C6 (spec §7 hot-reload eager-add): topology yaml just gained
  # `uri` as a neighbour of this peer's workspace. Merge it into the
  # reachable_set so the next prompt's `<reachable>` element exposes
  # it. Idempotent — already-known URIs are no-ops.
  def handle_info({:topology_neighbour_added, _ws, uri}, state) when is_binary(uri) do
    existing = state[:reachable_set] || MapSet.new()

    if MapSet.member?(existing, uri) do
      {:noreply, state}
    else
      Logger.info(
        "cc_process: topology hot-reload added uri session_id=#{state.session_id} uri=#{uri}"
      )

      {:noreply, %{state | reachable_set: MapSet.put(existing, uri)}}
    end
  end

  # Lazy-remove (spec §7): we deliberately do NOT handle a
  # `{:topology_neighbour_removed, _, _}` here — removals stay in-set
  # until session_end; cap revocation in capabilities.yaml is the
  # authoritative enforcement layer.
  def handle_info({:topology_loaded, _}, state), do: {:noreply, state}

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

    # PR-C C4 (spec §5.2 BGP-style learning): merge any URIs visible
    # in upstream meta into reachable_set. Operates on the just-stashed
    # meta so it sees the same shape stash_upstream_meta saw.
    state = learn_uris_from_event(state, event)

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

  # Every `dispatch_action/2` clause returns the (possibly updated)
  # state — keeps the reduce trivial. Only `send_input` actually
  # mutates state today (buffering when cc_mcp hasn't joined yet).
  defp dispatch_actions(actions, state),
    do: Enum.reduce(actions, state, &dispatch_action/2)

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
      state
    else
      # Prepend (O(1)); flush reverses on join.
      update_in(state.pending_notifications, &[envelope | &1])
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

    state
  end

  defp dispatch_action(unknown, state) do
    :telemetry.execute([:esr, :cc_process, :unknown_action], %{}, %{
      session_id: state.session_id,
      action: unknown
    })

    state
  end

  # `{:notification, envelope}` matches the existing admin-side
  # precedent in `Esr.Admin.Commands.Session.BranchEnd` — ChannelChannel
  # handle_info/2 routes both `{:push_envelope, _}` and
  # `{:notification, _}` identically, and sticking with the admin
  # convention keeps the ops + logs consistent.
  defp broadcast_notification(session_id, envelope) do
    # PR-E (2026-04-27 actor-topology-routing scenario-05 prep): the
    # `reachable` attribute is sent over Phoenix.PubSub which has no
    # default at-rest log line. Emit a single line per dispatch so e2e
    # harnesses can grep for "channel notification dispatched" with the
    # expected workspace + reachable shape, without standing up a
    # subscriber from bash. Truncated to the first 200 chars to keep
    # logs manageable.
    Logger.info(
      "cc_process: channel notification dispatched session_id=#{session_id} " <>
        "workspace=#{inspect(envelope["workspace"])} " <>
        "reachable_present=#{inspect(Map.has_key?(envelope, "reachable"))} " <>
        "reachable=#{inspect(envelope["reachable"] || "")}"
    )

    Phoenix.PubSub.broadcast(
      EsrWeb.PubSub,
      "cli:channel/" <> session_id,
      {:notification, envelope}
    )

    :ok
  end

  @doc false
  # Public only so cc_process_test.exs can assert envelope shape directly.
  # Pattern matches `Esr.Peers.TmuxProcess.build_capture_pane_argv/3` —
  # pure helper exposed to tests as `@doc false def` rather than pulled
  # apart into a behaviour. Not part of the stable API; the only
  # in-module caller is `dispatch_action(send_input)` above.
  def build_channel_notification(state, text) do
    ctx = state.proxy_ctx || %{}
    last = Map.get(state, :last_meta, %{})

    chat_id =
      Map.get(last, :chat_id) || Map.get(ctx, :chat_id) || Map.get(ctx, "chat_id") || ""

    app_id =
      Map.get(last, :app_id) || Map.get(ctx, :app_id) || Map.get(ctx, "app_id") || ""

    sender_id = Map.get(last, :sender_id) || ""

    base = %{
      "kind" => "notification",
      "source" => Map.get(ctx, "channel_adapter") || "feishu",
      # T12-comms-3d: prefer the per-event chat_id from FCP's meta — it's
      # authoritative for this specific inbound. Fall back to proxy_ctx
      # only for legacy callers that hadn't threaded it through yet.
      "chat_id" => chat_id,
      # T-PR-A T2: surface the originating Feishu app_id so cc_mcp can
      # render it on the <channel> tag and claude can echo it on reply.
      "app_id" => app_id,
      "thread_id" =>
        Map.get(last, :thread_id) || Map.get(ctx, :thread_id) || Map.get(ctx, "thread_id") || "",
      "message_id" => Map.get(last, :message_id) || "",
      # PR-C C5 (spec §8.1): `"user"` carries the open_id today (semantic
      # alias of `"user_id"`). The spec calls for `"user"` to become the
      # display name in v2 once the FAA → cc_process display-name cache
      # threading lands; for v1 cc_mcp keeps reading `"user"` so the
      # existing prompt template stays compatible. New consumers should
      # prefer `"user_id"`.
      "user" => sender_id,
      "user_id" => sender_id,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "content" => text
    }

    base
    |> maybe_put_workspace(chat_id, app_id)
    |> maybe_put_reachable(state)
  end

  # PR-C C5: workspace name attribute, looked up from
  # Esr.Workspaces.Registry.workspace_for_chat. Omitted when the
  # registry has no entry — keeps the tag stable for tests that don't
  # boot the registry GenServer.
  defp maybe_put_workspace(envelope, chat_id, app_id)
       when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
    case Esr.Workspaces.Registry.workspace_for_chat(chat_id, app_id) do
      {:ok, ws} -> Map.put(envelope, "workspace", ws)
      _ -> envelope
    end
  rescue
    # Workspaces.Registry GenServer not started in some unit tests.
    ArgumentError -> envelope
  end

  defp maybe_put_workspace(envelope, _, _), do: envelope

  # PR-D D2: `notifications/claude/channel` only forwards flat
  # attributes (`[A-Za-z0-9_]+`); nested elements are dropped. To
  # surface the reachable set in CC's prompt we encode the list as a
  # JSON-string attribute. Empty / missing reachable_set still omits
  # the field entirely so tags stay tight.
  defp maybe_put_reachable(envelope, state) do
    case state[:reachable_set] do
      nil ->
        envelope

      set ->
        if MapSet.size(set) == 0 do
          envelope
        else
          Map.put(envelope, "reachable", reachable_json(set))
        end
    end
  end

  defp reachable_json(set) do
    set
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.map(fn uri -> %{"uri" => uri, "name" => actor_display_name(uri)} end)
    |> Jason.encode!()
  end

  defp actor_display_name(uri) do
    case Esr.Uri.parse(uri) do
      {:ok, %Esr.Uri{segments: ["workspaces", _ws, "chats", chat_id]}} ->
        lookup_chat_name(chat_id) || short_id(chat_id)

      {:ok, %Esr.Uri{segments: ["users", open_id]}} ->
        # No display-name cache wired yet; show short open_id.
        short_id(open_id)

      {:ok, %Esr.Uri{segments: ["adapters", platform, app_id]}} ->
        "#{platform}:#{short_id(app_id)}"

      _ ->
        uri
    end
  end

  defp lookup_chat_name(chat_id) do
    Esr.Workspaces.Registry.list()
    |> Enum.find_value(fn ws ->
      Enum.find_value(ws.chats || [], fn
        %{"chat_id" => ^chat_id} = c -> c["name"]
        _ -> nil
      end)
    end)
  rescue
    ArgumentError -> nil
  end

  defp short_id(id) when is_binary(id) and byte_size(id) > 8 do
    "..." <> String.slice(id, -8, 8)
  end

  defp short_id(id), do: id

  # PR-9 T11b.6: pull message_id/sender_id/thread_id off the upstream
  # 3-tuple `{:text, text, meta}` and stash in state so dispatch_action
  # builds the notification envelope with real attribution instead of
  # empty strings.
  defp stash_upstream_meta(state, {:text, _bytes, meta}) when is_map(meta) do
    Map.put(state, :last_meta, meta)
  end

  defp stash_upstream_meta(state, _other), do: state

  # PR-C C4 (spec §4.3 + §5.2): mutate reachable_set with any URIs
  # visible in the just-arrived inbound. `meta.source` is the immediate
  # sender's URI (set by FCP from envelope["source"]); `meta.principal_id`
  # is the originating user's open_id, which we lift into a user URI.
  # Idempotent — already-known URIs are no-ops.
  defp learn_uris_from_event(state, {:text, _bytes, meta}) when is_map(meta) do
    new =
      [meta[:source], principal_uri(meta[:principal_id])]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reject(&MapSet.member?(state.reachable_set || MapSet.new(), &1))

    case new do
      [] ->
        state

      uris ->
        Logger.info(
          "cc_process: learned URIs session_id=#{state.session_id} uris=#{inspect(uris)}"
        )

        existing = state.reachable_set || MapSet.new()
        %{state | reachable_set: MapSet.union(existing, MapSet.new(uris))}
    end
  end

  defp learn_uris_from_event(state, _other), do: state

  defp principal_uri(open_id) when is_binary(open_id) and open_id != "",
    do: Esr.Topology.user_uri(open_id)

  defp principal_uri(_), do: nil

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

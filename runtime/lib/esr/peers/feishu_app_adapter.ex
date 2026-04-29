defmodule Esr.Peers.FeishuAppAdapter do
  @moduledoc """
  Peer.Stateful for one Feishu adapter instance. AdminSession-scope
  (one per `type: feishu` entry in `adapters.yaml`).

  Role: sole Elixir consumer of `adapter:feishu/<instance_id>`
  Phoenix-channel inbound frames. Routes each frame to the owning
  Session's FeishuChatProxy via `SessionRegistry.lookup_by_chat_thread/3`,
  or broadcasts `:new_chat_thread` on PubSub for SessionRouter (PR-3)
  to create a new session.

  **Identifier split (PR-9 T10)**:
  - `instance_id` — the `adapters.yaml` YAML key (operator-chosen,
    e.g. `"main_bot"`, `"feishu_app_e2e-mock"`). Doubles as the Phoenix
    topic suffix (`adapter:feishu/<instance_id>`) that the Python
    `adapter_runner` joins with `--instance-id`. The peer is registered
    in AdminSessionProcess under `:feishu_app_adapter_<instance_id>` so
    `EsrWeb.AdapterChannel.forward_to_new_chain/2` can find it.
  - `app_id` — the Feishu-platform application id issued by the Open
    Platform (e.g. `"cli_a9563cc03d399cc9"`). Kept in peer state for
    outbound Lark REST calls and for matching `workspaces.yaml`
    `chats[].app_id`, NOT used as the registration key.

  The spec (docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md
  §FeishuAppAdapter) originally conflated the two identifiers — it
  described the adapter as "terminating the Feishu WebSocket itself",
  in which case one identifier sufficed. PR-2's drift-finding moved WS
  ownership to the Python subprocess; PR-9 T10 finishes that
  reconciliation by splitting the identifiers in code and spec.

  **Today's architecture note**: the actual Feishu WebSocket is
  terminated by the Python `adapter_runner` subprocess; this Elixir
  peer receives frames via the existing Phoenix-channel plumbing.

  See spec §4.1 FeishuAppAdapter card, §5.1.
  """
  use Esr.Peer.Stateful
  use GenServer
  require Logger

  # Drop-Lane-A T1.1: Lane B owns the deny gate AND the user-facing
  # deny DM. When `Esr.PeerServer`'s inbound gate denies a Feishu
  # envelope (capabilities spec §7.2), it sends `{:dispatch_deny_dm,
  # principal_id, chat_id}` here; we emit the Chinese deny text via
  # the existing `{:outbound, _}` path, rate-limited per principal.
  # Spec: docs/superpowers/specs/2026-04-25-drop-lane-a-auth.md §Task 1.
  @deny_dm_text "你无权使用此 bot，请联系管理员授权。"
  @deny_dm_interval_ms 10 * 60 * 1000

  # PR-N 2026-04-28: per-chat rate limit for "this chat isn't bound to
  # any workspace" guide DMs. Without this, every inbound from an
  # unregistered chat would echo the registration command back —
  # noisy when a user is typing rapidly into a not-yet-configured
  # group. Same lifetime + scope as the deny DM rate limit (per FAA
  # peer, in-memory, lost on restart — that's fine).
  @guide_dm_interval_ms 10 * 60 * 1000

  def start_link(%{instance_id: instance_id} = args) when is_binary(instance_id) do
    GenServer.start_link(__MODULE__, args, name: via(instance_id))
  end

  @impl Esr.Peer
  def spawn_args(params) do
    instance_id = Esr.Peer.get_param(params, :instance_id) || "default"
    app_id = Esr.Peer.get_param(params, :app_id) || instance_id
    %{instance_id: instance_id, app_id: app_id}
  end

  defp via(instance_id), do: String.to_atom("feishu_app_adapter_#{instance_id}")

  @impl GenServer
  def init(%{instance_id: instance_id} = args) do
    :ok =
      Esr.AdminSessionProcess.register_admin_peer(
        String.to_atom("feishu_app_adapter_#{instance_id}"),
        self()
      )

    # PR-A T4: FCP's cross-app dispatch path looks up the target FAA
    # via Esr.PeerRegistry under "feishu_app_adapter_<instance_id>"
    # (string key — distinct from the AdminSessionProcess atom
    # registration above). The two registrations coexist: admin peers
    # use atoms (legacy via_tuple style); cross-app peer-to-peer
    # routing uses the binary-keyed PeerRegistry. Ignore re-register
    # races so a hot-reload that re-runs init/1 doesn't crash the
    # GenServer — the existing entry stays valid.
    _ = Esr.PeerRegistry.register("feishu_app_adapter_#{instance_id}", self())

    {:ok,
     %{
       instance_id: instance_id,
       app_id: args[:app_id] || instance_id,
       neighbors: args[:neighbors] || [],
       proxy_ctx: args[:proxy_ctx] || %{},
       # Drop-Lane-A T1.2: per-principal rate-limit for Lane B deny
       # DMs. Keys are principal_id (binary), values are
       # `:erlang.monotonic_time(:millisecond)` of the last DM emit.
       # Map lives in this FAA's GenServer state — multi-FAA topologies
       # rate-limit per-(principal, instance_id), matching today's
       # Python-side `_last_deny_ts` lifetime (single-FAA equivalent).
       # See spec §4 #2 for the multi-FAA soft regression note.
       deny_dm_last_emit: %{},
       # PR-N 2026-04-28: per-chat rate limit for unbound-chat guide
       # DMs. Keys are chat_id, values are last-emit time in ms.
       guide_dm_last_emit: %{}
     }}
  end

  @impl Esr.Peer.Stateful
  def handle_upstream({:inbound_event, envelope}, state) do
    # Real envelope shape (see py/src/esr/ipc/envelope.py make_event):
    #   %{"payload" => %{"event_type" => _, "args" => %{"chat_id" => _, ...}}}
    # PR-9 T10 e2e RCA: an earlier draft matched chat_id/thread_id
    # directly under payload; that never existed in the wire format,
    # but the unit fixtures used the wrong shape so the crash only
    # surfaced when real adapter traffic landed here. thread_id is
    # optional — group chats leave it empty string.
    args = get_in(envelope, ["payload", "args"]) || %{}
    chat_id = args["chat_id"] || ""
    thread_id = args["thread_id"] || ""

    # PR-21f: PendingActions interception (D15). If this principal+chat
    # has a registered destructive-action prompt awaiting confirm/cancel,
    # consume the bare-word answer here BEFORE slash parsing or
    # active-thread fallback. The PendingActions module forwards the
    # verdict to the registered reply_pid; the resolver decides what to
    # do (e.g. /end-session resolver calls Esr.Worktree.remove).
    principal_id = envelope["principal_id"] || ""
    text = (args["content"] || args["text"] || "") |> to_string()

    case Process.whereis(EsrWeb.PendingActions) &&
           EsrWeb.PendingActions.intercept?(principal_id, chat_id, text) do
      {:consume, _verdict} ->
        # Drop the inbound — consumer already notified.
        {:forward, [], state}

      _ ->
        do_handle_upstream_inbound(envelope, args, chat_id, thread_id, state)
    end
  end

  defp do_handle_upstream_inbound(envelope, args, chat_id, thread_id, state) do
    # PR-A T1: prefer args["app_id"] (Python adapter sets it post-PR-A);
    # fall back to state.instance_id for the case where an older Python
    # sidecar is still running mid-rollout. The fallback lets scenario
    # 01 still pass against an unchanged Python wire shape.
    app_id = args["app_id"] || state.instance_id

    case Esr.SessionRegistry.lookup_by_chat_thread(chat_id, app_id, thread_id) do
      {:ok, _session_id, %{feishu_chat_proxy: proxy_pid}} when is_pid(proxy_pid) ->
        send(proxy_pid, {:feishu_inbound, envelope})
        {:forward, [], state}

      :not_found ->
        # PR-N 2026-04-28: before falling through to session creation,
        # check whether this chat is even bound to a workspace. If
        # there's no binding in `workspaces.yaml`, SessionRouter would
        # silently fall back to workspace="default" — the user gets no
        # feedback in Feishu and no obvious "your chat isn't configured"
        # signal. Instead, DM the registration command (rate-limited)
        # and drop the inbound. Operators see a clear next-step in their
        # own DM rather than a silent no-op.
        case maybe_emit_unbound_chat_guide(state, chat_id, app_id) do
          {:guided, new_state} ->
            {:drop, :unbound_chat_guide_sent, new_state}

          :workspace_bound ->
            # P3-7: broadcast on the `session_router` topic. Tuple's second
            # slot is the resolved app_id — args["app_id"] when the Python
            # adapter populated it, else state.instance_id. Downstream
            # consumers (SessionRouter → FeishuAppProxy) look the peer up
            # by registry name `:feishu_app_adapter_<instance_id>`; the
            # PR-A T1 spec locks app_id == instance_id in our system.
            Phoenix.PubSub.broadcast(
              EsrWeb.PubSub,
              "session_router",
              {:new_chat_thread, app_id, chat_id, thread_id, envelope}
            )

            {:drop, :new_chat_thread_pending, state}

          :guide_rate_limited ->
            # Already DM'd this chat recently — silently drop without
            # also broadcasting (the operator hasn't acted on the
            # earlier guide yet, no point making more sessions either).
            {:drop, :unbound_chat_guide_rate_limited, state}
        end

      other ->
        Logger.warning(
          "FeishuAppAdapter: unexpected SessionRegistry reply #{inspect(other)}"
        )

        {:drop, :session_lookup_failed, state}
    end
  end

  @impl Esr.Peer.Stateful
  def handle_downstream({:outbound, envelope}, state) do
    # FCP (and other inbound peers) hand us a high-level envelope like
    # `%{"kind" => "reply"|"react"|"un_react", "args" => ...}`.
    # The Python feishu_adapter_runner filters inbound frames on
    # `kind=directive` (see `py/src/_ipc_common/frame.py`), so we must
    # wrap the high-level shape into a directive envelope the adapter's
    # `on_directive` can dispatch on. Wrap-not-broadcast-raw closes the
    # PR-9 T11a e2e RCA where "ack" replies left FCP but never reached
    # mock_feishu because the adapter's directive filter dropped them.
    # The topic suffix is `instance_id`, not Feishu-platform `app_id`.
    directive = wrap_as_directive(envelope, state)

    EsrWeb.Endpoint.broadcast(
      "adapter:feishu/#{state.instance_id}",
      "envelope",
      directive
    )

    {:forward, [], state}
  end

  # Map the peer-chain's high-level envelope kinds onto feishu
  # `adapter.on_directive/2` actions. `reply` → `send_message` with
  # args re-keyed to match the adapter's `_send_message` signature
  # (`chat_id` + `content`); `react` / `un_react` pass through since
  # their arg shapes already match.
  defp wrap_as_directive(%{"kind" => "reply", "args" => args}, state) do
    build_directive(
      state,
      "send_message",
      %{
        "chat_id" => args["chat_id"],
        "content" => args["text"] || ""
      }
    )
  end

  defp wrap_as_directive(%{"kind" => kind, "args" => args}, state)
       when kind in ["react", "un_react"] do
    build_directive(state, kind, args || %{})
  end

  # PR-9 T11b.5: send_file flows through unchanged — the Python feishu
  # adapter's `on_directive("send_file", args)` already expects
  # `%{chat_id, file_path}` (verified by
  # py/tests/adapter_runners/test_feishu_send_file.py). CC's `send_file`
  # MCP tool invokes this via FCP → FeishuAppProxy → here.
  defp wrap_as_directive(%{"kind" => "send_file", "args" => args}, state) do
    build_directive(state, "send_file", args || %{})
  end

  defp wrap_as_directive(%{"kind" => "directive"} = already_directive, _state) do
    # Caller already built a directive envelope (rare but legal path for
    # peers that want full control over action + args). Trust it.
    already_directive
  end

  defp wrap_as_directive(%{"kind" => other_kind} = env, state) do
    require Logger

    Logger.warning(
      "FeishuAppAdapter: downstream envelope kind=#{inspect(other_kind)} " <>
        "not recognised; forwarding as-is (will be dropped by adapter filter)"
    )

    env
    |> Map.put_new("source", "esr://localhost/admin/feishu_app_adapter_#{state.instance_id}")
  end

  defp build_directive(state, action, args) do
    %{
      "kind" => "directive",
      "id" => "d-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)),
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "type" => "directive",
      "source" => "esr://localhost/admin/feishu_app_adapter_#{state.instance_id}",
      "payload" => %{
        "adapter" => "feishu",
        "action" => action,
        "args" => args
      }
    }
  end

  # GenServer bridge: inbound messages are routed through the Stateful
  # callbacks via the shared Esr.Peer.Stateful.dispatch_{upstream,downstream}/3
  # helpers (PR-6 B1).
  @impl GenServer
  def handle_info({:inbound_event, _envelope} = msg, state),
    do: Esr.Peer.Stateful.dispatch_upstream(msg, state, __MODULE__)

  def handle_info({:outbound, _envelope} = msg, state),
    do: Esr.Peer.Stateful.dispatch_downstream(msg, state, __MODULE__)

  # Drop-Lane-A T1.3: Lane B deny-DM dispatch. `peer_server.ex`'s
  # inbound gate emits this message after capability denial; here we
  # rate-limit per principal (10 min window, see @deny_dm_interval_ms)
  # and dispatch a `{:outbound, %{"kind" => "reply", ...}}` directive
  # which routes through the existing handle_downstream path, lands as
  # a directive on `adapter:feishu/<instance_id>`, and is sent over
  # the wire by the Python adapter.
  #
  # Empty/missing principal_id is dropped silently — the regex match
  # in peer_server.ex's `dispatch_deny_dm/1` already filters these,
  # but the belt-and-braces guard here means any internally-fired bad
  # dispatch can't crash this GenServer.
  def handle_info({:dispatch_deny_dm, principal_id, chat_id}, state)
      when is_binary(principal_id) and principal_id != "" and is_binary(chat_id) and chat_id != "" do
    now = :erlang.monotonic_time(:millisecond)
    # `:erlang.monotonic_time/1` may be negative — never compare against
    # a literal default like `0` (which would mark first dispatch as
    # rate-limited on a freshly-booted node). Treat "never seen" as a
    # forced-fire branch.
    last = Map.get(state.deny_dm_last_emit, principal_id)

    if is_nil(last) or now - last >= @deny_dm_interval_ms do
      send(
        self(),
        {:outbound,
         %{"kind" => "reply", "args" => %{"chat_id" => chat_id, "text" => @deny_dm_text}}}
      )

      {:noreply, %{state | deny_dm_last_emit: Map.put(state.deny_dm_last_emit, principal_id, now)}}
    else
      Logger.debug(
        "FAA Lane B deny-DM suppressed by rate-limit " <>
          "principal=#{inspect(principal_id)} chat_id=#{inspect(chat_id)} " <>
          "instance_id=#{inspect(state.instance_id)}"
      )

      {:noreply, state}
    end
  end

  # Catch-all for malformed dispatch tuples (empty/missing principal_id
  # or chat_id, non-binary types). Drop and stay alive — never crash
  # the GenServer for a bad dispatch.
  def handle_info({:dispatch_deny_dm, _principal_id, _chat_id}, state) do
    Logger.warning(
      "FAA Lane B deny-DM ignored: malformed dispatch tuple " <>
        "(empty/non-binary principal_id or chat_id) instance_id=#{inspect(state.instance_id)}"
    )

    {:noreply, state}
  end

  # PR-N 2026-04-28: send a registration-command guide DM when an
  # inbound arrives for a chat with no `workspaces.yaml` binding.
  # Returns `:workspace_bound` (proceed with new_chat_thread broadcast),
  # `{:guided, new_state}` (DM emitted, drop inbound), or
  # `:guide_rate_limited` (recently DM'd, drop quietly).
  defp maybe_emit_unbound_chat_guide(state, chat_id, app_id)
       when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
    case Esr.Workspaces.Registry.workspace_for_chat(chat_id, app_id) do
      {:ok, _ws} ->
        :workspace_bound

      :not_found ->
        now = :erlang.monotonic_time(:millisecond)
        last = Map.get(state.guide_dm_last_emit, chat_id)

        if is_nil(last) or now - last >= @guide_dm_interval_ms do
          text = guide_text(chat_id, app_id, state.instance_id)

          send(
            self(),
            {:outbound,
             %{"kind" => "reply", "args" => %{"chat_id" => chat_id, "text" => text}}}
          )

          new_state = %{
            state
            | guide_dm_last_emit: Map.put(state.guide_dm_last_emit, chat_id, now)
          }

          {:guided, new_state}
        else
          :guide_rate_limited
        end
    end
  end

  # Empty chat_id or app_id — fall back to broadcast path; SessionRouter
  # will surface its own error in logs and we have no chat to DM anyway.
  defp maybe_emit_unbound_chat_guide(_state, _chat_id, _app_id), do: :workspace_bound

  defp guide_text(chat_id, app_id, _instance_id) do
    """
    👋 这个 chat 还没在 ESR 注册 workspace，所以收到的消息会被忽略。

    在 esr 仓库里跑（注意 --env 选 prod 或 dev）：

      ./esr.sh --env=<prod|dev> workspace add <workspace_name> \\
          --owner <esr_username> \\
          --root <主 git 仓库路径> \\
          --start-cmd scripts/esr-cc.sh \\
          --role dev \\
          --chat #{chat_id}:#{app_id}:dm

    注册后，给本 bot 发：
      /new-session <workspace_name> name=<session_name> cwd=<worktree 路径> worktree=<分支名>

    会话就会拉起来（每个 session 一个独立 worktree，从 origin/main fork）。

    （这条消息 10 分钟内不会重复发送。）
    """
  end
end

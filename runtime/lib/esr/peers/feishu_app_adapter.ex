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
       guide_dm_last_emit: %{},
       # PR-21i 2026-04-29: per-feishu_id rate limit for unbound-user
       # guide DMs. Keys are feishu open_id (`ou_*`), values are
       # last-emit time in ms. Same 10-min window as the chat guide.
       user_guide_dm_last_emit: %{}
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
        # PR-21q + PR-21t: handle bootstrap slashes BEFORE the unbound-
        # chat / unbound-user guide gates. Without this, the chat-guide
        # DM tells operators to do something the chat-guide itself
        # prevents (chicken-and-egg).
        cond do
          inline_bootstrap_slash?(text) ->
            # /help, /whoami, /doctor: handled inline (no SlashHandler
            # hop) so we can DM the result directly without binding
            # requirements.
            handle_inline_bootstrap_slash(text, chat_id, principal_id, args, state)

          routed_bootstrap_slash?(text) ->
            # /new-workspace: route to SlashHandler → Dispatcher →
            # Workspace.New. Cap check happens at the Dispatcher (so
            # workspace.create is enforced); chat-binding requirement
            # is bypassed (chat-guide doesn't intercept).
            route_to_slash_handler(envelope, chat_id, state)

          true ->
            # PR-21i: user-guide DM when user_id unbound AND chat IS
            # workspace-bound. Mutually exclusive with chat-guide below.
            app_id = args["app_id"] || state.instance_id
            user_id = envelope["user_id"] || args["user_id"]

            case maybe_emit_unbound_user_guide(state, user_id, chat_id, app_id) do
              {:guided, new_state} ->
                {:drop, :unbound_user_guide_sent, new_state}

              _ ->
                do_handle_upstream_inbound(envelope, args, chat_id, thread_id, state)
            end
        end
    end
  end

  # PR-21q + PR-21t: split bootstrap slashes by handling style.
  #
  # `inline_bootstrap_slash?/1` — read-only helpers that just emit text:
  #   /help, /whoami, /doctor
  #
  # `routed_bootstrap_slash?/1` — slash that creates state but should
  # work even in unbound chat:
  #   /new-workspace (operator-facing exit from "chat unbound" state)

  defp inline_bootstrap_slash?(text), do: slash_head(text) in ~w(/help /whoami /doctor)

  defp routed_bootstrap_slash?(text), do: slash_head(text) in ~w(/new-workspace)

  defp slash_head(text) do
    text
    |> to_string()
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2, trim: true)
    |> List.first()
  end

  # PR-21t: route an unbound-chat-eligible slash to the AdminSession
  # SlashHandler, exactly as a chat-bound inbound would. Cap check
  # happens at Dispatcher, so workspace.create / etc. are still
  # enforced. The SlashHandler reply lands at the FeishuChatProxy of
  # whichever chat owns the inbound — but in the unbound-chat case,
  # there's no proxy. So we use ourself (FAA) as the reply target,
  # then convert {:reply, text} into a chat DM via the outbound path.
  defp route_to_slash_handler(envelope, chat_id, state) do
    case Esr.AdminSessionProcess.slash_handler_ref() do
      {:ok, slash_pid} ->
        # SlashHandler reads text from envelope.payload.text. Construct
        # it from envelope.payload.args.content to match the legacy
        # chat-bound shape SlashHandler expects.
        text = (get_in(envelope, ["payload", "args", "content"]) || "") |> to_string()
        envelope_with_text = put_in(envelope, ["payload", "text"], text)

        # Track the chat_id so when SlashHandler sends {:reply, _},
        # we know where to DM it back. The map is small (~few entries
        # at any time, all bootstrap flows are interactive).
        new_state =
          state
          |> Map.put(:bootstrap_pending_chat, Map.put(state[:bootstrap_pending_chat] || %{}, slash_pid, chat_id))

        send(slash_pid, {:slash_cmd, envelope_with_text, self()})
        {:drop, :bootstrap_slash_routed, new_state}

      :error ->
        require Logger
        Logger.warning("FeishuAppAdapter: routed bootstrap slash but no SlashHandler registered")
        {:drop, :no_slash_handler, state}
    end
  end

  defp handle_inline_bootstrap_slash(text, chat_id, principal_id, args, state) do
    text = String.trim(text)
    app_id = args["app_id"] || state.instance_id

    reply =
      cond do
        text == "/help" or String.starts_with?(text, "/help ") ->
          help_text()

        text == "/whoami" or String.starts_with?(text, "/whoami ") ->
          whoami_text(principal_id, chat_id, app_id)

        text == "/doctor" or String.starts_with?(text, "/doctor ") ->
          doctor_text(principal_id, chat_id, app_id)

        true ->
          "unknown bootstrap slash"
      end

    send(
      self(),
      {:outbound, %{"kind" => "reply", "args" => %{"chat_id" => chat_id, "text" => reply}}}
    )

    {:drop, :bootstrap_slash_replied, state}
  end

  # PR-21r 2026-04-29: /help is a clean command reference (man-style).
  # Status check + bootstrap walk-through moved to /doctor.
  defp help_text do
    """
    📖 ESR slash commands

    诊断（任何状态都可用）：
      /help            — 显示这份命令清单
      /whoami          — 显示你的身份 + chat / workspace 绑定状态
      /doctor          — 状态检查 + 卡在哪步的 bootstrap 步骤建议

    Workspace（需要 user 已绑 + workspace.create cap）：
      /new-workspace <name>
                       — 创建新 workspace，自动绑当前 chat
      /workspace info [<name>]
                       — 显示 workspace 配置（owner/role/chats/metadata）

    Sessions（需要 user 已绑 + chat 绑了 workspace）：
      /new-session <ws> name=<…> root=<repo> cwd=<wt> worktree=<branch>
                       — 启 CC session（git worktree fork from origin/main）
      /sessions
      /workspace sessions [<name>]
                       — 列当前 workspace 的 live sessions
      /end-session <name>
                       — 结束 session（worktree 干净则自动 prune）

    诊断细节（cap、URI、状态）请用 /doctor。
    """
  end

  defp whoami_text(principal_id, chat_id, app_id) do
    user_resolved =
      if Process.whereis(Esr.Users.Registry) do
        case Esr.Users.Registry.lookup_by_feishu_id(principal_id) do
          {:ok, username} -> "esr user: #{username}"
          :not_found -> "未绑定 (open_id: #{principal_id})"
        end
      else
        "(registry 未运行)"
      end

    workspace =
      case Esr.Workspaces.Registry.workspace_for_chat(chat_id, app_id) do
        {:ok, ws} -> ws
        :not_found -> "(无)"
      end

    """
    🪪 你的 ESR 身份

    open_id: #{principal_id}
    esr 用户: #{user_resolved}
    chat_id: #{chat_id}
    app_id (instance): #{app_id}
    workspace: #{workspace}
    """
  end

  # PR-21r 2026-04-29: /doctor — full state diagnostic + bootstrap
  # walk-through tailored to whichever blocker the operator is hitting.
  # Replaces the status-aware text formerly emitted by /help.
  defp doctor_text(principal_id, chat_id, app_id) do
    {user_line, user_ok} =
      if Process.whereis(Esr.Users.Registry) do
        case Esr.Users.Registry.lookup_by_feishu_id(principal_id) do
          {:ok, username} ->
            {"  ✅ 用户身份: 已绑定 esr user `#{username}`", true}

          :not_found ->
            {"  ❌ 用户身份: 未绑定 (你的 open_id: `#{principal_id}`)", false}
        end
      else
        {"  ⚠️ 用户身份: Esr.Users.Registry 未运行", false}
      end

    {chat_line, chat_ok, ws_name} =
      case Esr.Workspaces.Registry.workspace_for_chat(chat_id, app_id) do
        {:ok, ws} -> {"  ✅ Chat 绑定: workspace `#{ws}`", true, ws}
        :not_found -> {"  ❌ Chat 绑定: 未绑定任何 workspace", false, nil}
      end

    next_steps =
      cond do
        not user_ok ->
          """
          ## 下一步：先绑定 esr user

          在终端跑：

            ./esr.sh --env=#{env_hint(app_id)} user list
            ./esr.sh --env=#{env_hint(app_id)} user bind-feishu <esr_user> #{principal_id}

          这会顺带 grant `workspace.create` / `session:default/create` 等 4 个
          基础 cap，你之后就能在 chat 里直接发 slash 命令。

          需要全权限（admin）的话：

            ./esr.sh --env=#{env_hint(app_id)} cap grant #{principal_id} admin
          """

        not chat_ok ->
          """
          ## 下一步：在本 chat 创建 workspace

          直接在这个 chat 里发：

            /new-workspace <workspace_name>

          自动绑当前 chat。然后：

            /new-session <workspace_name> name=<session_name> \\
                root=<主 git 仓库路径> \\
                cwd=<worktree 路径> \\
                worktree=<分支名>
          """

        true ->
          """
          ## 状态健康 ✅

          Workspace `#{ws_name}` 已绑。可用：

            /new-session #{ws_name} name=<session_name> \\
                root=<repo> cwd=<worktree 路径> worktree=<分支>
            /sessions
            /end-session <name>
          """
      end

    """
    🩺 ESR 状态诊断

    #{user_line}
    #{chat_line}

    #{String.trim(next_steps)}
    """
  end

  # Best-effort env hint from instance_id. Conventions:
  # - "esr_helper" / "esr_dev_helper" map to prod / dev
  # - everything else: ambiguous — operator picks
  defp env_hint("esr_dev_helper"), do: "dev"
  defp env_hint("esr_helper"), do: "prod"
  defp env_hint(_), do: "<prod|dev>"

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

  # PR-21t: SlashHandler replies arrive as {:reply, text} after we
  # routed a bootstrap slash via route_to_slash_handler/3. Convert to
  # an outbound DM directed at the chat the inbound came from. The
  # `bootstrap_pending_chat` map (FAA state) tracks the slash_pid →
  # chat_id binding; we drain it on each reply (single-flight is
  # the common case for bootstrap interactions).
  def handle_info({:reply, text}, state) when is_binary(text) do
    pending = state[:bootstrap_pending_chat] || %{}

    chat_id =
      if map_size(pending) > 0 do
        pending |> Map.values() |> List.first()
      else
        nil
      end

    if is_binary(chat_id) and chat_id != "" do
      send(
        self(),
        {:outbound,
         %{"kind" => "reply", "args" => %{"chat_id" => chat_id, "text" => text}}}
      )

      {:noreply, Map.put(state, :bootstrap_pending_chat, %{})}
    else
      require Logger
      Logger.warning("FeishuAppAdapter: SlashHandler reply but no pending bootstrap chat_id")
      {:noreply, state}
    end
  end

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

  # PR-21i 2026-04-29: send a `esr user bind-feishu` guide DM when an
  # inbound carries a `user_id` (Feishu open_id) that isn't bound to
  # any esr user yet. Pre-conditions checked here (so callers don't
  # have to):
  #
  # - `user_id` is non-empty
  # - chat is already workspace-bound (otherwise the chat-guide DM
  #   takes precedence and we don't want to pile two DMs)
  # - `Esr.Users.Registry` is up
  # - `lookup_by_feishu_id(user_id)` returns `:not_found`
  # - 10-min rate limit on (user_id) is not yet exceeded
  #
  # Returns `{:guided, new_state}` (DM emitted, drop inbound) or
  # `:user_bound_or_anonymous` (proceed normally).
  defp maybe_emit_unbound_user_guide(state, user_id, chat_id, app_id)
       when is_binary(user_id) and user_id != "" and
              is_binary(chat_id) and chat_id != "" do
    with {:ok, _ws} <- Esr.Workspaces.Registry.workspace_for_chat(chat_id, app_id),
         true <- Process.whereis(Esr.Users.Registry) != nil,
         :not_found <- Esr.Users.Registry.lookup_by_feishu_id(user_id) do
      now = :erlang.monotonic_time(:millisecond)
      last = Map.get(state.user_guide_dm_last_emit, user_id)

      if is_nil(last) or now - last >= @guide_dm_interval_ms do
        text = user_guide_text(user_id)

        send(
          self(),
          {:outbound,
           %{"kind" => "reply", "args" => %{"chat_id" => chat_id, "text" => text}}}
        )

        new_state = %{
          state
          | user_guide_dm_last_emit:
              Map.put(state.user_guide_dm_last_emit, user_id, now)
        }

        {:guided, new_state}
      else
        :user_guide_rate_limited
      end
    else
      _ -> :user_bound_or_anonymous
    end
  end

  defp maybe_emit_unbound_user_guide(_state, _user_id, _chat_id, _app_id),
    do: :user_bound_or_anonymous

  defp user_guide_text(user_id) do
    """
    👋 你的 Feishu 身份还没绑到 ESR 用户。先看一下已注册的 esr user：

      ./esr.sh --env=<prod|dev> user list

    然后跑：

      ./esr.sh --env=<prod|dev> user bind-feishu <esr_username> #{user_id}

    绑完之后给本 bot 发任意消息就会走 ESR 流程。

    你的 Feishu open_id 是 #{user_id}（复制即可）。

    （这条消息 10 分钟内不会重复发送。）
    """
  end

  defp guide_text(chat_id, app_id, _instance_id) do
    """
    👋 这个 chat 还没在 ESR 注册 workspace，所以收到的消息会被忽略。

    两种注册方式（任选其一）：

    A. 在本 chat 直接发 slash 命令（推荐 — 自动绑当前 chat）：

       /new-workspace <workspace_name>

       owner 缺省 = 你（已绑定的 esr user）；role / start_cmd 用默认值。
       PR-22 之后 workspace 不再绑特定 git 仓库——repo 是 per-session 的。

    B. 在 esr 仓库 CLI 里跑（注意 --env 选 prod 或 dev）：

       ./esr.sh --env=<prod|dev> workspace add <workspace_name> \\
           --owner <esr_username> \\
           --start-cmd scripts/esr-cc.sh \\
           --role dev \\
           --chat #{chat_id}:#{app_id}:dm

    注册后给本 bot 发：

      /new-session <workspace_name> name=<session_name> \\
          root=<主 git 仓库路径> cwd=<worktree 路径> worktree=<分支名>

    会话就会拉起来（每个 session 一个独立 worktree，从 origin/main fork）。

    （这条消息 10 分钟内不会重复发送。）
    """
  end
end

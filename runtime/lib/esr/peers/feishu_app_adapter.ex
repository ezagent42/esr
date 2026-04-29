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

  @behaviour Esr.Role.Boundary
  use Esr.Peer.Stateful
  use GenServer
  require Logger

  # PR-21x: Lane B deny gate + deny-DM rate limit moved to
  # `Esr.Peers.CapGuard`. CapGuard sends `{:outbound, %{"kind" => "reply",
  # ...}}` directly to this FAA pid; the existing handle_downstream/2
  # path wraps it as a directive on `adapter:feishu/<id>`.

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
       proxy_ctx: args[:proxy_ctx] || %{}
       # PR-21w: rate-limit state for unbound-chat / unbound-user guide
       # DMs lives in `Esr.Peers.UnboundChatGuard` / `UnboundUserGuard`.
       # PR-21x: deny-DM rate-limit moved to `Esr.Peers.CapGuard`.
       # FAA state is now down to passive routing context only.
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

    # PR-21f: PendingActionsGuard interception (D15). If this principal+chat
    # has a registered destructive-action prompt awaiting confirm/cancel,
    # consume the bare-word answer here BEFORE slash parsing or
    # active-thread fallback. The PendingActionsGuard module forwards the
    # verdict to the registered reply_pid; the resolver decides what to
    # do (e.g. /end-session resolver calls Esr.Worktree.remove).
    principal_id = envelope["principal_id"] || ""
    text = (args["content"] || args["text"] || "") |> to_string()

    case Process.whereis(EsrWeb.PendingActionsGuard) &&
           EsrWeb.PendingActionsGuard.intercept?(principal_id, chat_id, text) do
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
            # PR-21w: extracted into Esr.Peers.UnboundUserGuard.
            app_id = args["app_id"] || state.instance_id
            user_id = (envelope["user_id"] || args["user_id"] || "") |> to_string()

            case Esr.Peers.UnboundUserGuard.check(user_id, chat_id, app_id) do
              {:emit, text} ->
                send_guide_dm(chat_id, text)
                {:drop, :unbound_user_guide_sent, state}

              :rate_limited ->
                {:drop, :unbound_user_guide_rate_limited, state}

              :passthrough ->
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
        # PR-N 2026-04-28 / PR-21w: before falling through to session
        # creation, check whether this chat is even bound to a workspace
        # via Esr.Peers.UnboundChatGuard. Without the gate, SessionRouter
        # would silently fall back to workspace="default" and the
        # operator gets no signal that their chat isn't configured.
        case Esr.Peers.UnboundChatGuard.check(chat_id, app_id, state.instance_id) do
          {:emit, text} ->
            send_guide_dm(chat_id, text)
            {:drop, :unbound_chat_guide_sent, state}

          :rate_limited ->
            # Already DM'd this chat recently — silently drop without
            # also broadcasting (the operator hasn't acted on the
            # earlier guide yet, no point making more sessions either).
            {:drop, :unbound_chat_guide_rate_limited, state}

          :passthrough ->
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

  # PR-21x: `{:dispatch_deny_dm, _, _}` handle_info clauses removed —
  # `Esr.Peers.CapGuard` now sends `{:outbound, ...}` directly to this
  # FAA pid, so the existing `{:outbound, _}` handle_info clause does
  # the wrapping. No FAA-side rate-limit state remains.

  # PR-21w: outbound entrypoint shared by the unbound-chat / unbound-user
  # guards. Both Guard modules return `{:emit, text}` and let FAA do the
  # actual outbound (the Guards don't know about the FAA's outbound
  # plumbing — directive-wrap happens in handle_downstream).
  defp send_guide_dm(chat_id, text) do
    send(
      self(),
      {:outbound, %{"kind" => "reply", "args" => %{"chat_id" => chat_id, "text" => text}}}
    )
  end
end

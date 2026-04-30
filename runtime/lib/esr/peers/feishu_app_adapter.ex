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
       proxy_ctx: args[:proxy_ctx] || %{},
       # PR-21κ Phase 4: ref → chat_id for slash dispatches in flight.
       # When SlashHandler.dispatch returns `{:reply, text, ref}` we
       # look up the originating chat to DM the reply back to.
       # Replaces the pre-PR-21κ on-demand `bootstrap_pending_chat`
       # map populated by the deleted `route_to_slash_handler/3`.
       slash_pending_chat: %{}
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
        # PR-21κ Phase 4: any slash inbound goes straight to
        # SlashHandler.dispatch. SlashHandler itself enforces
        # workspace/user binding requirements per the slash-routes.yaml
        # entry, so the FAA no longer needs to pre-classify "bootstrap
        # vs. routed" slashes — that distinction lived in a hardcoded
        # cond here pre-PR-21κ and is now data in the yaml.
        cond do
          slash?(text) ->
            dispatch_slash(envelope, text, chat_id, state)

          true ->
            # PR-21i: user-guide DM when user_id unbound AND chat IS
            # workspace-bound. Mutually exclusive with chat-guide below.
            # PR-21w: extracted into Esr.Peers.UnboundUserGuard.
            # Slashes never reach this branch (handled above) so this
            # only runs for free-text inbounds bound for a CC session.
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

  defp slash?(text) do
    text
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("/")
  end

  # PR-21κ Phase 4: yaml-driven slash dispatch. Generates a ref,
  # tracks it in `slash_pending_chat`, and asks SlashHandler to do
  # the actual routing. The reply lands here as
  # `{:reply, text, ref}` (handle_info clause below).
  defp dispatch_slash(envelope, text, chat_id, state) do
    envelope_with_text = put_in(envelope, ["payload", "text"], text)
    ref = make_ref()
    Esr.Peers.SlashHandler.dispatch(envelope_with_text, self(), ref)

    new_state = put_in(state, [:slash_pending_chat, ref], chat_id)
    {:drop, :slash_dispatched, new_state}
  end

  # PR-21κ Phase 4: help_text / whoami_text private helpers deleted —
  # both moved to `Esr.Admin.Commands.{Help,Whoami}` and routed via
  # SlashHandler.dispatch + Dispatcher (yaml-driven).

  # PR-21κ Phase 4: doctor_text + env_hint deleted —
  # `Esr.Admin.Commands.Doctor` owns the bootstrap walk-through now.

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

  # PR-21κ Phase 4: SlashHandler.dispatch replies arrive as
  # `{:reply, text, ref}`. Look up the ref in `slash_pending_chat`
  # (set when we cast dispatch in `dispatch_slash/4`) to find the
  # originating chat, then DM the formatted reply.
  def handle_info({:reply, text, ref}, state) when is_reference(ref) and is_binary(text) do
    pending = state[:slash_pending_chat] || %{}

    case Map.pop(pending, ref) do
      {chat_id, rest} when is_binary(chat_id) and chat_id != "" ->
        send(
          self(),
          {:outbound,
           %{"kind" => "reply", "args" => %{"chat_id" => chat_id, "text" => text}}}
        )

        {:noreply, Map.put(state, :slash_pending_chat, rest)}

      {nil, _} ->
        Logger.warning(
          "FeishuAppAdapter: slash reply for unknown ref #{inspect(ref)}"
        )

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

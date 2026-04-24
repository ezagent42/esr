defmodule Esr.Peers.FeishuAppAdapter do
  @moduledoc """
  Peer.Stateful for one Feishu adapter instance. AdminSession-scope
  (one per `type: feishu` entry in `adapters.yaml`).

  Role: sole Elixir consumer of `adapter:feishu/<instance_id>`
  Phoenix-channel inbound frames. Routes each frame to the owning
  Session's FeishuChatProxy via `SessionRegistry.lookup_by_chat_thread/2`,
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

    {:ok,
     %{
       instance_id: instance_id,
       app_id: args[:app_id] || instance_id,
       neighbors: args[:neighbors] || [],
       proxy_ctx: args[:proxy_ctx] || %{}
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

    case Esr.SessionRegistry.lookup_by_chat_thread(chat_id, thread_id) do
      {:ok, _session_id, %{feishu_chat_proxy: proxy_pid}} when is_pid(proxy_pid) ->
        send(proxy_pid, {:feishu_inbound, envelope})
        {:forward, [], state}

      :not_found ->
        # P3-7: broadcast on the `session_router` topic. Tuple's second
        # slot is the Phoenix-routing key (i.e. `instance_id`) — not
        # the Feishu-platform `app_id` — because downstream consumers
        # (SessionRouter → FeishuAppProxy) look the peer up by registry
        # name `:feishu_app_adapter_<instance_id>`. SessionRouter's
        # `app_id` local variable is still so-named (PR-9 T10 left the
        # wider rename for later); the value it carries is this
        # `instance_id`.
        Phoenix.PubSub.broadcast(
          EsrWeb.PubSub,
          "session_router",
          {:new_chat_thread, state.instance_id, chat_id, thread_id, envelope}
        )

        {:drop, :new_chat_thread_pending, state}

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
end

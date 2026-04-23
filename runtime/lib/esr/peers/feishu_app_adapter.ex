defmodule Esr.Peers.FeishuAppAdapter do
  @moduledoc """
  Peer.Stateful for one Feishu app_id. AdminSession-scope (one per app
  declared in adapters.yaml).

  Role: sole Elixir consumer of `adapter:feishu/<app_id>` Phoenix-channel
  inbound frames. Routes each frame to the owning Session's FeishuChatProxy
  via `SessionRegistry.lookup_by_chat_thread/2`, or broadcasts `:new_chat_thread`
  on PubSub for SessionRouter (PR-3) to create a new session.

  **Today's architecture note**: the actual Feishu WebSocket is terminated
  by the Python `adapter_runner` subprocess; this Elixir peer receives
  frames via the existing Phoenix-channel plumbing (`EsrWeb.AdapterChannel`
  forwards `{:inbound_event, envelope}` to this peer once P2-11 retargets
  the channel).

  Registers itself in AdminSessionProcess under `:feishu_app_adapter_<app_id>`
  so other peers (and test harnesses) can look it up symbolically.

  See spec §4.1 FeishuAppAdapter card, §5.1.
  """
  use Esr.Peer.Stateful
  use GenServer
  require Logger

  def start_link(%{app_id: app_id} = args) when is_binary(app_id) do
    GenServer.start_link(__MODULE__, args, name: via(app_id))
  end

  defp via(app_id), do: String.to_atom("feishu_app_adapter_#{app_id}")

  @impl Esr.Peer.Stateful
  def init(%{app_id: app_id} = args) do
    :ok =
      Esr.AdminSessionProcess.register_admin_peer(
        String.to_atom("feishu_app_adapter_#{app_id}"),
        self()
      )

    {:ok,
     %{
       app_id: app_id,
       neighbors: args[:neighbors] || [],
       proxy_ctx: args[:proxy_ctx] || %{}
     }}
  end

  @impl Esr.Peer.Stateful
  def handle_upstream({:inbound_event, envelope}, state) do
    chat_id = get_in(envelope, ["payload", "chat_id"])
    thread_id = get_in(envelope, ["payload", "thread_id"])

    case Esr.SessionRegistry.lookup_by_chat_thread(chat_id, thread_id) do
      {:ok, _session_id, %{feishu_chat_proxy: proxy_pid}} when is_pid(proxy_pid) ->
        send(proxy_pid, {:feishu_inbound, envelope})
        {:forward, [], state}

      :not_found ->
        # P3-7: broadcast on the `session_router` topic with the
        # canonical tuple shape `{:new_chat_thread, app_id, chat_id,
        # thread_id, envelope}` (app_id first — matches the wiring
        # FeishuAppAdapter owns; SessionRouter is the sole subscriber).
        Phoenix.PubSub.broadcast(
          EsrWeb.PubSub,
          "session_router",
          {:new_chat_thread, state.app_id, chat_id, thread_id, envelope}
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
    # PR-2 leaves outbound emission wired through the existing adapter
    # broadcast path (EsrWeb.Endpoint.broadcast on adapter:feishu/<app_id>).
    # PR-3 can move this into CCProcess directly.
    EsrWeb.Endpoint.broadcast(
      "adapter:feishu/#{state.app_id}",
      "envelope",
      envelope
    )

    {:forward, [], state}
  end

  # GenServer bridge: inbound messages are routed through the Stateful
  # callbacks. Same pattern used by the other Stateful peers in PR-2.
  @impl GenServer
  def handle_info({:inbound_event, _envelope} = msg, state) do
    case handle_upstream(msg, state) do
      {:forward, _msgs, new_state} -> {:noreply, new_state}
      {:drop, _reason, new_state} -> {:noreply, new_state}
    end
  end

  def handle_info({:outbound, _envelope} = msg, state) do
    {_, _msgs, new_state} = handle_downstream(msg, state)
    {:noreply, new_state}
  end
end

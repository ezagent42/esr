defmodule EsrWeb.ChannelChannel do
  @moduledoc """
  Phoenix.Channel for esr-channel MCP bridges (spec §3.2, §5.3).

  Topic: `cli:channel/<session_id>`. One channel process per CC
  session WS. Routes `tool_invoke` to the owning feishu_thread
  PeerServer; server-pushes `notification` and `session_killed`
  frames; marks the session offline on terminate so telemetry and
  the watchdog see it.
  """
  use Phoenix.Channel
  require Logger

  alias Esr.SessionRegistry

  @impl Phoenix.Channel
  def join("cli:channel/" <> session_id, _payload, socket) do
    SessionRegistry.register(session_id,
      ws_pid: self(),
      chat_ids: [],
      app_ids: [],
      workspace: ""
    )

    {:ok, %{registered: true}, assign(socket, :session_id, session_id)}
  end

  @impl Phoenix.Channel
  def handle_in("envelope", %{"kind" => "session_register"} = payload, socket) do
    session_id = socket.assigns.session_id
    chats = payload["chats"] || []
    chat_ids = Enum.map(chats, &(&1["chat_id"]))
    app_ids = chats |> Enum.map(&(&1["app_id"])) |> Enum.uniq()

    SessionRegistry.register(session_id,
      ws_pid: self(),
      chat_ids: chat_ids,
      app_ids: app_ids,
      workspace: payload["workspace"] || ""
    )

    {:reply, :ok, socket}
  end

  def handle_in("envelope", %{"kind" => "tool_invoke"} = payload, socket) do
    # v0.2 P6 replaces this stub with a real PeerServer forward.
    req_id = payload["req_id"]
    {:reply, {:ok, %{"kind" => "tool_result", "req_id" => req_id,
                     "ok" => false, "error" =>
                     %{"type" => "not_implemented",
                       "message" => "P6 not landed"}}}, socket}
  end

  def handle_in("envelope", _payload, socket) do
    {:reply, {:error, %{reason: "unknown envelope kind"}}, socket}
  end

  @impl Phoenix.Channel
  def handle_info({:push_envelope, envelope}, socket) do
    push(socket, "envelope", envelope)
    {:noreply, socket}
  end

  @impl Phoenix.Channel
  def terminate(_reason, socket) do
    if sid = socket.assigns[:session_id] do
      SessionRegistry.mark_offline(sid)
      :telemetry.execute([:esr, :session, :offline], %{},
        %{session_id: sid, reason: :ws_closed})
    end
    :ok
  end
end

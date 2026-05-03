defmodule EsrWeb.ChannelChannel do
  @moduledoc """
  Phoenix.Channel for esr-channel MCP bridges (spec §3.2, §5.3).

  Topic: `cli:channel/<session_id>`. One channel process per CC
  session WS. Routes `tool_invoke` to the owning feishu_thread
  Entity.Server; server-pushes `notification` and `session_killed`
  frames; marks the session offline on terminate so telemetry and
  the watchdog see it.
  """
  use Phoenix.Channel
  require Logger

  alias Esr.Resource.AdapterSocket.Registry, as: AdapterSocketRegistry

  @impl Phoenix.Channel
  def join("cli:channel/" <> session_id, _payload, socket) do
    # PR-9 T11b.4a: reject duplicate join on the same session_id rather
    # than silently last-writer-wins. See
    # `docs/notes/mcp-transport-orphan-session-hazard.md` — cc-openclaw
    # hit this when two CC clients both registered `cc:linyilun.root`,
    # and the fix here stops ESR from replicating the hazard.
    #
    # A registration with status=:online AND a still-alive ws_pid means
    # another client is legitimately holding the slot. Reject the new
    # join — the remote can retry after the owner disconnects (which
    # flips status=:offline via `ChannelChannel.terminate/2` →
    # `Registry.mark_offline/1`).
    case AdapterSocketRegistry.lookup(session_id) do
      {:ok, %{status: :online, ws_pid: existing_ws}} when is_pid(existing_ws) ->
        if existing_ws != self() and Process.alive?(existing_ws) do
          Logger.warning(
            "channel_channel: rejecting duplicate join for session_id=" <>
              inspect(session_id) <>
              " — already held by ws_pid=" <> inspect(existing_ws)
          )

          {:error, %{reason: "already_joined", existing_ws_pid: inspect(existing_ws)}}
        else
          do_join(session_id, socket)
        end

      _ ->
        do_join(session_id, socket)
    end
  end

  defp do_join(session_id, socket) do
    AdapterSocketRegistry.register(session_id,
      ws_pid: self(),
      chat_ids: [],
      app_ids: [],
      workspace: "",
      principal_id: nil,
      workspace_name: nil
    )

    socket =
      socket
      |> assign(:session_id, session_id)
      |> assign(:principal_id, nil)
      |> assign(:workspace_name, nil)

    # PR-9 T12-comms-3c: signal CCProcess so it can flush any send_input
    # notifications buffered during the ~10s window between pipeline
    # spawn and cc_mcp joining this topic. Without this flush, the
    # triggering inbound message that auto-created the session would
    # be lost (Phoenix.PubSub drops broadcasts with zero subscribers).
    # See docs/notes/cc-mcp-pubsub-race.md.
    Phoenix.PubSub.broadcast(
      EsrWeb.PubSub,
      "cc_mcp_ready/" <> session_id,
      {:cc_mcp_ready, session_id}
    )

    {:ok, %{registered: true}, socket}
  end

  # Capabilities spec §6.2/§6.3 — CC session worker declares its
  # principal_id (the admin/user running CC) and workspace_name (which
  # workspace row this session operates in) on register. Both end up
  # on the Registry row AND on the socket's assigns so the
  # tool_invoke handler can inject principal_id into the arity-6
  # {:tool_invoke, ...} tuple that Lane B (CAP-4) enforces against.
  #
  # principal_id default: ``ESR_BOOTSTRAP_PRINCIPAL_ID`` — lets the
  # bootstrap admin run tools before any capabilities.yaml grant
  # exists (matches Lane A bootstrap in Esr.Resource.Capability).
  @impl Phoenix.Channel
  def handle_in("envelope", %{"kind" => "session_register"} = payload, socket) do
    session_id = socket.assigns.session_id
    chats = payload["chats"] || []
    chat_ids = Enum.map(chats, &(&1["chat_id"]))
    app_ids = chats |> Enum.map(&(&1["app_id"])) |> Enum.uniq()
    principal_id = payload["principal_id"] || System.get_env("ESR_BOOTSTRAP_PRINCIPAL_ID")
    workspace_name = payload["workspace_name"]

    AdapterSocketRegistry.register(session_id,
      ws_pid: self(),
      chat_ids: chat_ids,
      app_ids: app_ids,
      workspace: payload["workspace"] || "",
      principal_id: principal_id,
      workspace_name: workspace_name
    )

    socket =
      socket
      |> assign(:principal_id, principal_id)
      |> assign(:workspace_name, workspace_name)

    {:reply, :ok, socket}
  end

  def handle_in("envelope", %{"kind" => "tool_invoke"} = payload, socket) do
    session_id = socket.assigns.session_id
    req_id = payload["req_id"]
    tool = payload["tool"]
    args = payload["args"] || %{}
    principal_id =
      socket.assigns[:principal_id] ||
        System.get_env("ESR_BOOTSTRAP_PRINCIPAL_ID")

    peer_name = "thread:" <> session_id

    case Registry.lookup(Esr.Entity.Registry, peer_name) do
      [{peer_pid, _}] ->
        send(peer_pid, {:tool_invoke, req_id, tool, args, self(), principal_id})
        {:noreply, socket}

      [] ->
        result = %{
          "kind" => "tool_result",
          "req_id" => req_id,
          "ok" => false,
          "error" => %{
            "type" => "peer_vanished",
            "message" => "no thread peer for session " <> session_id
          }
        }

        push(socket, "envelope", result)
        {:noreply, socket}
    end
  end

  def handle_in("envelope", _payload, socket) do
    {:reply, {:error, %{reason: "unknown envelope kind"}}, socket}
  end

  @impl Phoenix.Channel
  def handle_info({:push_envelope, envelope}, socket) do
    push(socket, "envelope", envelope)
    {:noreply, socket}
  end

  # Admin-originated notifications (e.g. `cleanup_check_requested`
  # from `Esr.Admin.Commands.Scope.BranchEnd` on the non-force path;
  # was `Session.End` before the PR-3 P3-9 rename).
  # `Phoenix.PubSub.broadcast(EsrWeb.PubSub, "cli:channel/<sid>", {:notification, ...})`
  # reaches this channel because Phoenix.Channel auto-subscribes the
  # channel pid to the PubSub topic matching its join topic.
  def handle_info({:notification, payload}, socket) when is_map(payload) do
    push(socket, "envelope", payload)
    {:noreply, socket}
  end

  def handle_info({:tool_result, req_id, result}, socket) do
    push(
      socket,
      "envelope",
      Map.merge(result, %{"kind" => "tool_result", "req_id" => req_id})
    )

    {:noreply, socket}
  end

  @impl Phoenix.Channel
  def terminate(_reason, socket) do
    if sid = socket.assigns[:session_id] do
      AdapterSocketRegistry.mark_offline(sid)
      :telemetry.execute([:esr, :session, :offline], %{},
        %{session_id: sid, reason: :ws_closed})
    end
    :ok
  end
end

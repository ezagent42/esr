defmodule EsrWeb.AttachChannel do
  @moduledoc """
  PR-23: browser-side terminal attach via Phoenix.Channel (replaces
  PR-22's LiveView).

  Topic shape: `attach:<session_id>`. On join, subscribes to PubSub
  topic `pty:<sid>`; raw stdout chunks from `Esr.Peers.PtyProcess`
  become `push("stdout", %{data: bytes})` to the browser. Client sends
  `stdin` / `resize` events back; we forward to PtyProcess.

  On `:pty_closed` we push `ended` so the client can render an overlay.
  """

  use Phoenix.Channel

  @impl true
  def join("attach:" <> sid, _payload, socket) when is_binary(sid) and sid != "" do
    Phoenix.PubSub.subscribe(EsrWeb.PubSub, "pty:" <> sid)
    {:ok, assign(socket, :sid, sid)}
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "bad_topic"}}

  @impl true
  def handle_in("stdin", %{"data" => data}, socket) when is_binary(data) do
    Esr.Peers.PtyProcess.write(socket.assigns.sid, data)
    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => c, "rows" => r}, socket)
      when is_integer(c) and is_integer(r) do
    Esr.Peers.PtyProcess.resize(socket.assigns.sid, c, r)
    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:pty_stdout, data}, socket) do
    push(socket, "stdout", %{data: data})
    {:noreply, socket}
  end

  def handle_info(:pty_closed, socket) do
    push(socket, "ended", %{reason: ""})
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end

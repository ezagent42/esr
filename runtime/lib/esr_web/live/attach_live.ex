defmodule EsrWeb.AttachLive do
  @moduledoc """
  PR-22: browser-side terminal attach for ESR sessions.

  Mounted at `/sessions/:sid/attach`. Subscribes to Phoenix.PubSub
  topic `pty:<sid>`; the session's `Esr.Peers.PtyProcess` peer broadcasts
  raw stdout chunks (via `on_raw_stdout/2`, before line-splitting) so
  ANSI escape sequences arrive at xterm.js intact.

  Stdin keystrokes / paste come back via `phx-hook="XtermAttach"` →
  `pushEvent("stdin", {data})` → `Esr.Peers.PtyProcess.write/2`.
  Window resize fires `:exec.winsz/3` (SIGWINCH) via `resize/3`.

  On session end the peer's `on_terminate/1` broadcasts a bare
  `:pty_closed` and the LiveView paints a "[session ended]" banner.

  No auth in v1 (Tailnet trust per PR-22 spec).
  """

  use EsrWeb, :live_view

  @impl true
  def mount(%{"sid" => sid}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EsrWeb.PubSub, "pty:" <> sid)
    end

    {:ok,
     assign(socket,
       sid: sid,
       terminal_id: "term-" <> sid,
       ended?: false
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="position:fixed;inset:0;display:flex;flex-direction:column;background:#1e1e1e;">
      <div :if={@ended?} style="background:#332200;color:#ffaa33;padding:6px 10px;font-size:12px;font-family:monospace;">
        [session ended — link no longer attached to a live PTY]
      </div>
      <div
        id={@terminal_id}
        phx-hook="XtermAttach"
        phx-update="ignore"
        data-sid={@sid}
        style="flex:1;min-height:0;width:100%;"
      >
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("stdin", %{"data" => data}, socket) do
    Esr.Peers.PtyProcess.write(socket.assigns.sid, data)
    {:noreply, socket}
  end

  def handle_event("resize", %{"cols" => c, "rows" => r}, socket)
      when is_integer(c) and is_integer(r) do
    Esr.Peers.PtyProcess.resize(socket.assigns.sid, c, r)
    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:pty_stdout, data}, socket) do
    {:noreply, push_event(socket, "stdout", %{data: data})}
  end

  def handle_info(:pty_closed, socket) do
    {:noreply,
     socket
     |> assign(ended?: true)
     |> push_event("ended", %{reason: ""})}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end

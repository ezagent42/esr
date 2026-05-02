defmodule EsrWeb.PtySocket do
  @moduledoc """
  Raw binary WebSocket transport for browser-side PTY attach.

  Replaces the PR-23 `Phoenix.Channel`-based `AttachChannel` because
  Phoenix.Channel JSON-serialises every payload, mangling ANSI ESC
  sequences and any byte ≥ 0x80 — which both garbled xterm.js's
  rendering and prevented xterm.js's auto-replies to claude's
  Device Attributes / XTVERSION queries from coming back as valid
  bytes, leaving claude blocked at boot.

  ## Wire protocol (matches the spirit of ttyd)

  - **Server → client**: binary frames containing **raw PTY stdout**
    bytes (no command-byte prefix; we only ever push one stream).
  - **Client → server, binary frames**: raw stdin bytes (keystrokes
    + xterm.js-generated cap-query replies).
  - **Client → server, text frames**: JSON `{"cols": N, "rows": N}`
    resize messages — split out from the binary stream so neither
    side has to disambiguate by inspecting payload shape.

  ## Connection

  URL: `/attach_socket/websocket?sid=<session_id>`. The browser passes
  `sid` as a query param at WebSocket handshake (matches the existing
  `window.ESR_SID` injection in the attach HTML shell).

  On connect we subscribe to PubSub topic `pty:<sid>`; PtyProcess
  broadcasts `{:pty_stdout, bytes}` there, and we forward bytes
  unchanged as binary frames. `:pty_closed` closes the socket.
  """

  @behaviour Phoenix.Socket.Transport

  require Logger

  @impl true
  def child_spec(_opts), do: :ignore

  @impl true
  def connect(%{params: params}) do
    case Map.get(params, "sid") do
      sid when is_binary(sid) and sid != "" ->
        {:ok, %{sid: sid}}

      _ ->
        Logger.warning("pty_socket: connect rejected — missing sid query param")
        :error
    end
  end

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(EsrWeb.PubSub, "pty:" <> state.sid)
    {:ok, state}
  end

  @impl true
  def handle_in({data, [opcode: :binary]}, state) when is_binary(data) do
    # Raw stdin from browser (keystrokes + xterm.js terminal-cap replies).
    Esr.Peers.PtyProcess.write(state.sid, data)
    {:ok, state}
  end

  def handle_in({text, [opcode: :text]}, state) when is_binary(text) do
    # JSON control message — only resize for now.
    case Jason.decode(text) do
      {:ok, %{"cols" => cols, "rows" => rows}}
      when is_integer(cols) and is_integer(rows) and cols > 0 and rows > 0 ->
        Esr.Peers.PtyProcess.resize(state.sid, cols, rows)
        {:ok, state}

      _ ->
        Logger.debug("pty_socket: ignoring unrecognised text frame on sid=#{state.sid}")
        {:ok, state}
    end
  end

  def handle_in(_other, state), do: {:ok, state}

  @impl true
  def handle_info({:pty_stdout, data}, state) when is_binary(data) do
    # Pass PTY bytes straight through as a binary frame — no JSON,
    # no UTF-8 round-trip, no escaping.
    {:push, {:binary, data}, state}
  end

  def handle_info(:pty_closed, state) do
    # Graceful close so the browser sees a clean shutdown.
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end

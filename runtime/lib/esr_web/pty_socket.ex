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

  URL: `/attach_socket/websocket?token=<phoenix_token>`. The browser
  passes a `Phoenix.Token` HMAC-signed payload as the `token` query
  param at WebSocket handshake. The token's plaintext is the
  pty_actor_id; salt is `"pty_attach"`; TTL is 600 seconds (10 min).

  Pre-2026-05-09 this used `?sid=<actor_id>` plain — anyone who learned
  the actor_id (clipboard leak, screenshot, log spillover) could attach
  to a live PTY. The signed token closes that gap; the actor_id no
  longer appears in any URL.

  On connect we verify the token and subscribe to PubSub topic
  `pty:<actor_id>`; PtyProcess broadcasts `{:pty_stdout, bytes}` there,
  and we forward bytes unchanged as binary frames. `:pty_closed` closes
  the socket. The internal state field stays named `sid` to keep the
  downstream code path (init/handle_in/handle_info) unchanged — only
  the auth path is new.
  """

  @behaviour Phoenix.Socket.Transport

  require Logger

  # Salt + TTL must match Esr.Commands.Pty.Attach (token signer) and
  # EsrWeb.AttachController (page-level pre-check).
  @token_salt "pty_attach"
  @token_max_age_seconds 600

  @impl true
  def child_spec(_opts), do: :ignore

  @impl true
  def connect(%{params: %{"token" => token}}) when is_binary(token) and token != "" do
    case Phoenix.Token.verify(EsrWeb.Endpoint, @token_salt, token,
           max_age: @token_max_age_seconds
         ) do
      {:ok, actor_id} when is_binary(actor_id) and actor_id != "" ->
        Logger.info("pty_socket: connect verified actor_id=#{actor_id}")
        {:ok, %{sid: actor_id}}

      {:error, reason} ->
        Logger.warning("pty_socket: connect rejected reason=#{inspect(reason)}")
        :error
    end
  end

  def connect(_other) do
    Logger.warning("pty_socket: connect rejected — missing or empty token query param")
    :error
  end

  @impl true
  def init(state) do
    Logger.info("pty_socket.init: client attached sid=#{state.sid}")
    Phoenix.PubSub.subscribe(EsrWeb.PubSub, "pty:" <> state.sid)

    # PR-24 follow-up: announce the browser attach so FCP's boot bridge
    # can stop trying to default-resize the PTY. Without this, FCP's
    # `:send_default_winsize` (120×40 at 1s post-init) fires AFTER the
    # browser sent its real viewport (e.g. 164×39) and clobbers it.
    # The browser-resize is silently overridden and operators see their
    # viewport stuck at the bridge default.
    Phoenix.PubSub.broadcast(
      EsrWeb.PubSub,
      "pty_attach/" <> state.sid,
      {:pty_attach, state.sid}
    )

    {:ok, state}
  end

  @impl true
  def handle_in({data, [opcode: :binary]}, state) when is_binary(data) do
    # Raw stdin from browser (keystrokes + xterm.js terminal-cap replies).
    Esr.Entity.PtyProcess.write(state.sid, data)
    {:ok, state}
  end

  def handle_in({text, [opcode: :text]}, state) when is_binary(text) do
    # JSON control message — only resize for now.
    case Jason.decode(text) do
      {:ok, %{"cols" => cols, "rows" => rows}}
      when is_integer(cols) and is_integer(rows) and cols > 0 and rows > 0 ->
        Logger.info("pty_socket.resize sid=#{state.sid} cols=#{cols} rows=#{rows}")
        Esr.Entity.PtyProcess.resize(state.sid, cols, rows)
        {:ok, state}

      other ->
        Logger.info("pty_socket: ignoring unrecognised text frame on sid=#{state.sid} payload=#{inspect(other)}")
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

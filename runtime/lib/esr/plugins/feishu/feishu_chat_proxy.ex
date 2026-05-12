defmodule Esr.Plugins.Feishu.FeishuChatProxy do
  @moduledoc """
  Per-Session Peer.Stateful: entry point for inbound Feishu messages
  into the Session. Detects slash commands (leading `/` in the first
  token) and short-circuits to the Scope.Admin's SlashHandler; all
  other messages are forwarded downstream to CCProcess (PR-9 T5a).

  PR-9 T5 architectural invariant: **react is proxy-emitted, not
  CC-emitted**. FeishuChatProxy is the sole owner of Feishu-specific
  `react` / `un_react` semantics. On successful forward to CC, this
  proxy emits a `react` action (default emoji `EYES` / 👀) as a
  delivery acknowledgement. When CC's reply lands — carrying the
  optional `reply_to_message_id` field (PR-9 T5c MCP schema) — the
  proxy un-reacts that message_id BEFORE forwarding the reply text.
  A hypothetical SlackChatProxy would implement its own analogous
  react/un-react without ever touching CC or esr-channel.

  Spec §4.1 FeishuChatProxy card, §5.1, §5.3.
  """

  @behaviour Esr.Role.Pipeline
  use Esr.Entity.Stateful
  use GenServer
  require Logger

  # M-1.5: compile-time role constant. Consumed by `register_attrs/2`
  # in init/1 below so callers (M-2+) can resolve this peer via
  # `Esr.ActorQuery.list_by_role(sid, :feishu_chat_proxy)` without
  # grepping for a string literal.
  @role :feishu_chat_proxy

  @default_react_emoji "EYES"

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl Esr.Entity
  def spawn_args(params) do
    # PR-A T4: thread `app_id` (the source app this FCP serves) and
    # `principal_id` (the human authenticated for the originating
    # inbound) into init args. Both are needed by the cross-app
    # `dispatch_tool_invoke("reply")` branch — `app_id` to detect that
    # `args.app_id != state.app_id`, `principal_id` to gate on
    # `workspace:<target>/msg.send`.
    %{
      chat_id: Esr.Entity.get_param(params, :chat_id) || "",
      thread_id: Esr.Entity.get_param(params, :thread_id) || "",
      app_id: Esr.Entity.get_param(params, :app_id) || "",
      principal_id: Esr.Entity.get_param(params, :principal_id) || ""
    }
  end

  @impl GenServer
  def init(args) do
    ctx = Map.get(args, :proxy_ctx, %{})
    session_id = Map.fetch!(args, :session_id)

    # Phase A.4b: PtyProcess registers under "pty:<actor_id>" post-Phase-A.4.
    # FCP is currently only spawned via AgentSpawner (single-agent path),
    # which goes through Factory.spawn_peer and does NOT thread actor_id —
    # the PtyProcess peer's init falls back to `actor_id ||= session_id`,
    # so PTY registers under "pty:<session_id>". Mirror that fallback here.
    #
    # When/if FCP gains a multi-agent spawn path (via InstanceRegistry),
    # the primary agent's pty_actor_id is the right binding — resolve via
    # InstanceRegistry first, then fall back to session_id keying for the
    # AgentSpawner path (and for any race where FCP boots before the row
    # is written).
    pty_actor_id = resolve_pty_actor_id(session_id)

    base = %{
      session_id: session_id,
      pty_actor_id: pty_actor_id,
      chat_id: Map.fetch!(args, :chat_id),
      thread_id: Map.fetch!(args, :thread_id),
      # PR-A T4: home app + authenticated principal. Source order:
      #   args.<key> (set by spawn_args/1 from session_router params)
      #   proxy_ctx[:<key>] (T1's FAA-side propagation may add it)
      #   "" (defensive default — keeps test setups that don't thread
      #     these args from crashing on Map.fetch!)
      app_id: Map.get(args, :app_id) || Map.get(ctx, :app_id) || "",
      principal_id:
        Map.get(args, :principal_id) || Map.get(ctx, :principal_id) || "",
      proxy_ctx: ctx,
      # PR-21λ 2026-05-01: `pending_reacts` removed — FAA owns the
      # universal react/un_react lifecycle now (PR-9 T5's per-FCP
      # bookkeeping was redundant once FAA went one-react-per-inbound).
      #
      # 2026-05-09: `pending_media` tracks in-flight `download_file`
      # directives keyed by directive id. Replaces the pre-2026-05-09
      # blocking `receive` in `build_directive_fn/1` that stalled this
      # GenServer's mailbox for up to 30 s on every non-text inbound.
      # Each entry is the `directive_ctx` from `Esr.Resource.Media.Inbound.handle/2`
      # extended with the originating `:envelope` so the
      # `handle_info({:directive_ack, ...})` clause can resume
      # `forward_media_to_cc/3` with the correct meta.
      pending_media: %{}
    }

    # D1 new pattern — explicitly lift a ctx field into state under a
    # string key so downstream peers reading the thread-state map (e.g.
    # Entity.Server.build_emit_for_tool) see a typed, named slot instead of
    # reaching into the opaque proxy_ctx blob. Fallback "feishu" matches
    # the top-level spawn_pipeline default (session_router.ex). String
    # key + mixed-key map requires Map.put (Elixir disallows `key:` /
    # `"key" =>` in the same literal).
    state = Map.put(base, "channel_adapter", Map.get(ctx, :channel_adapter) || "feishu")

    # PR-9 T11b.4: register as `thread:<session_id>` in Entity.Registry so
    # `EsrWeb.ChannelChannel.handle_in("envelope", {kind: "tool_invoke", ...})`
    # can route CC's MCP tool calls (reply / react / send_file) here via
    # `Registry.lookup(Esr.Entity.Registry, "thread:" <> session_id)`.
    _ = Registry.register(Esr.Entity.Registry, "thread:" <> session_id, nil)

    # M-1.5: also register in Index 2 (`{sid, name}`) and Index 3
    # (`{sid, role}`) so `Esr.ActorQuery.find_by_name/2` and
    # `list_by_role/2` resolve this peer (M-2+ call sites).
    name_for_index = Map.get(args, :name) || ("fcp-" <> session_id)
    state = Map.put(state, :name, name_for_index)

    _ =
      try do
        Esr.Entity.Registry.register_attrs("thread:" <> session_id, %{
          session_id: session_id,
          name: name_for_index,
          role: @role
        })
      catch
        _, _ -> :ok
      end

    # PR-24 step 2: PTY ↔ Feishu boot bridge. Before cc_mcp joins
    # `cli:channel/<sid>`, claude's TUI is the only window into what
    # the agent is doing — and at boot time it's typically waiting for
    # the operator to answer the `--dangerously-load-development-channels`
    # warning dialog. We subscribe to the session's PTY topic so we
    # can mirror claude's stdout into the bound Feishu chat (debounced,
    # ANSI-stripped) and let the operator answer dialogs by typing
    # text in the chat. `cc_mcp_ready` flips the bridge off; from
    # there cc_mcp's `notifications/claude/channel` path takes over.
    state = Map.merge(state, %{
      boot_mode: true,
      pty_buffer: "",
      pty_flush_timer: nil,
      # PR-185 follow-up (in-process unblock): claude binary opens a
      # `--dangerously-load-development-channels` confirmation dialog at
      # boot. Pre-this-PR an external bash+websocat helper answered it,
      # which had a known timing fragility (4s pre-roll didn't always
      # cover claude's startup latency). Since FCP already subscribes
      # to `pty:<sid>` and PtyProcess.write/2 is a public API, we can
      # detect the dialog's text in the stdout stream and reply "1\r"
      # directly via erlexec — no bash, no websocat, no agent-browser.
      # `dev_channels_confirmed` flips once after the first write so
      # subsequent occurrences of the signature in the buffer (it stays
      # there until flush) don't trigger duplicate writes.
      dev_channels_confirmed: false
    })

    if Process.whereis(EsrWeb.PubSub) do
      # Phase A.4b: PTY topic now keys on actor_id (see PtyProcess
      # on_raw_stdout). cc_mcp_ready / pty_attach remain session-scoped
      # — they are session-level events, not pty-scoped.
      Phoenix.PubSub.subscribe(EsrWeb.PubSub, "pty:" <> pty_actor_id)
      Phoenix.PubSub.subscribe(EsrWeb.PubSub, "cc_mcp_ready/" <> session_id)
      Phoenix.PubSub.subscribe(EsrWeb.PubSub, "pty_attach/" <> session_id)
    end

    # PR-24 step 2: claude's TUI needs a real winsize before it'll
    # render anything past the initial control sequences (DA query +
    # cursor mode setup). It queries via TIOCGWINSZ — the
    # `COLUMNS`/`LINES` env vars in PtyProcess.os_env are NOT
    # sufficient. /attach in xterm.js sends a resize as soon as the
    # WebSocket connects; without a client attached, claude waits
    # forever and the boot bridge has nothing to mirror.
    #
    # Schedule a default 120×40 resize ~1s after init **only if no
    # browser has attached**. PtySocket broadcasts `{:pty_attach, sid}`
    # on connect so FCP can cancel this — otherwise the default fires
    # AFTER the browser sent its real viewport and clobbers it (e.g.
    # operator at 164×39 ends up stuck at 120×40).
    state = Map.put(state, :winsize_pending_ref,
      Process.send_after(self(), :send_default_winsize, 1_000))

    {:ok, state}
  end

  @impl Esr.Entity.Stateful
  def handle_upstream({:feishu_inbound, envelope}, state) do
    # Real envelope shape (see py/src/esr/ipc/envelope.py make_event):
    #   %{"payload" => %{"event_type" => _, "args" => %{
    #     "chat_id" => _, "content" => _, "message_id" => _, ...}}}
    # PR-9 T11a RCA: this peer was reading `payload.text` / `payload.message_id`
    # directly — a shape that never existed on the wire but was pinned by
    # fixture-based tests that used the same wrong shape. Same class of bug
    # fixed in FeishuAppAdapter during T10.
    args = get_in(envelope, ["payload", "args"]) || %{}
    msg_type = args["msg_type"] || "text"
    text = args["content"] || ""
    message_id = args["message_id"] || ""

    # PR-9 T11b.6a: propagate `message_id`, `sender_id`, `thread_id`
    # downstream so CCProcess can build a notifications/claude/channel
    # meta map with real attributes. T11b.6 consumes these; a 2-tuple
    # `{:text, text}` would leave CC with `meta.user=""` etc.
    #
    # T12-comms-3d (2026-04-24): also carry `chat_id`. Without it, the
    # notification envelope reached claude with `"chat_id" => ""` and
    # claude refused to call `mcp__esr-channel__reply` ("I couldn't
    # find a chat_id in the inbound <channel> tag, so I'm replying
    # here as text"), dropping the ack to the terminal instead of the
    # reply channel. FCP sees chat_id on every inbound; thread it.
    meta = %{
      message_id: message_id,
      sender_id: args["sender_id"] || "",
      thread_id: args["thread_id"] || "",
      chat_id: args["chat_id"] || "",
      # T-PR-A T2: thread the originating Feishu app_id downstream so
      # CCProcess.build_channel_notification can surface it on the
      # notification envelope cc_mcp ships into claude as a <channel>
      # tag. T3 will require claude to echo this back on `reply`.
      app_id: args["app_id"] || "",
      # Pass the inbound `source` URI + `principal_id` through to
      # cc_process. Both fields are nil-safe — envelopes that don't
      # carry them still produce valid meta maps. (M-3 deleted the
      # downstream BGP-style learning that originally consumed them;
      # the fields are kept for the channel-meta envelope surface.)
      source: envelope["source"],
      principal_id: envelope["principal_id"] || args["principal_id"]
    }

    # PR-21κ Phase 6: slash detection moved upstream into the FAA's
    # handle_upstream gate — slashes never reach FCP anymore. FCP is
    # now purely "forward inbound to the CC session".
    #
    # Task 2.4: branch on msg_type — text takes the existing path;
    # image/file/audio dispatches through Esr.Resource.Media.Inbound;
    # unknown types are logged and dropped.
    case msg_type do
      "text" ->
        forward_text_and_react(text, message_id, meta, state)

      kind when kind in ["image", "file", "audio"] ->
        # 2026-05-09: do_handle_non_text_inbound is now async — it may
        # mutate state (registering an entry under :pending_media) but
        # never blocks. Thread its returned state onward so the next
        # inbound sees the updated pending_media map.
        {:ok, new_state} = do_handle_non_text_inbound(envelope, args, kind, meta, state)
        {:drop, :non_text_handled, new_state}

      other ->
        Logger.info(
          "feishu_chat_proxy: unsupported msg_type #{inspect(other)} — dropping",
          session_id: state.session_id
        )

        {:drop, :unsupported_msg_type, state}
    end
  end

  # PR-9 T5c: CC's reply lands here via the cc_process neighbor (see
  # dispatch_action(:reply, ...) in cc_process.ex). If the CC reply
  # carries `reply_to_message_id`, un-react that message BEFORE
  # forwarding the reply text — keeps all Feishu-specific
  # react/un-react semantics inside FeishuChatProxy.
  @impl Esr.Entity.Stateful
  def handle_downstream({:reply, text}, state) do
    forward_reply(text, nil, state)
  end

  def handle_downstream({:reply, text, opts}, state) when is_map(opts) do
    forward_reply(text, Map.get(opts, :reply_to_message_id), state)
  end

  @impl GenServer
  def handle_info({:feishu_inbound, _} = msg, state) do
    case handle_upstream(msg, state) do
      {:forward, _outbound, ns} -> {:noreply, ns}
      {:drop, _reason, ns} -> {:noreply, ns}
    end
  end

  def handle_info({:reply, _text} = msg, state) do
    case handle_downstream(msg, state) do
      {:forward, _, ns} -> {:noreply, ns}
      {:drop, _, ns} -> {:noreply, ns}
    end
  end

  def handle_info({:reply, _text, _opts} = msg, state) do
    case handle_downstream(msg, state) do
      {:forward, _, ns} -> {:noreply, ns}
      {:drop, _, ns} -> {:noreply, ns}
    end
  end

  # PR-9 T11b.4: cc_mcp's MCP tool calls (reply / react / send_file)
  # arrive here via `EsrWeb.ChannelChannel.handle_in("envelope",
  # %{"kind" => "tool_invoke"}, socket)` → `send(peer_pid,
  # {:tool_invoke, req_id, tool, args, channel_pid, principal_id})`.
  # Each tool maps onto an outbound directive via T10's wrap_as_directive
  # path, then we send the tool_result back on the CC session's channel
  # so cc_mcp's pending future resolves.
  #
  # 6-tuple arity disambiguation (spec §9a): ChannelChannel always sends
  # 6 positional args; FCP's existing 2-tuple and 3-tuple `:reply` shapes
  # (from CCProcess upstream) never collide. Docstring-only reminder —
  # don't add a 4-tuple reply variant that would blur this boundary.
  def handle_info({:tool_invoke, req_id, tool, args, channel_pid, _principal_id}, state) do
    state = dispatch_tool_invoke(tool, args, req_id, channel_pid, state)
    {:noreply, state}
  end

  # 2026-05-09: async resumption of `do_handle_non_text_inbound/5`.
  # `directive_ack` is broadcast on `directive_ack:<id>` after the
  # Feishu adapter completes the `download_file` directive. The match
  # on a known id in `state.pending_media` distinguishes "ours" from
  # acks belonging to other directives the adapter may emit; unknown
  # ids drop quietly (could be a late ack after timeout, or a directive
  # initiated by another peer subscribed to the same topic).
  def handle_info({:directive_ack, %{"id" => id, "payload" => payload}}, state) do
    case Map.pop(state.pending_media, id) do
      {nil, _} ->
        # Not ours (or already timed out). Drop quietly.
        {:noreply, state}

      {%{msg_type: msg_type, meta: meta_ctx, envelope: _envelope}, remaining} ->
        if Process.whereis(EsrWeb.PubSub) do
          Phoenix.PubSub.unsubscribe(EsrWeb.PubSub, "directive_ack:" <> id)
        end

        new_state = %{state | pending_media: remaining}

        case payload do
          %{"ok" => true, "result" => %{"uri" => uri}} ->
            envelope_out = %{msg_type: msg_type, content: uri, meta: meta_ctx}
            forward_media_to_cc(envelope_out, meta_ctx, new_state)

          %{"ok" => false, "error" => err} ->
            Logger.warning(
              "feishu_chat_proxy: download_file failed " <>
                "session_id=#{new_state.session_id} error=#{inspect(err)}"
            )

          other ->
            Logger.warning(
              "feishu_chat_proxy: directive_ack unexpected shape " <>
                "session_id=#{new_state.session_id} got=#{inspect(other)}"
            )
        end

        {:noreply, new_state}
    end
  end

  # 2026-05-09: cleanup for download directives the adapter never acked.
  # Pre-2026-05-09 the blocking `receive` in `build_directive_fn/1`
  # surfaced timeouts as `{:error, {:directive_timeout, id}}`; in the
  # async model we just log + drop the entry so memory doesn't grow
  # unboundedly. (The originating user already saw the inbound message
  # in Feishu; without an ack we have no URI to forward to claude.)
  def handle_info({:pending_media_timeout, id}, state) do
    case Map.pop(state.pending_media, id) do
      {nil, _} ->
        # Already acked.
        {:noreply, state}

      {_dropped, remaining} ->
        if Process.whereis(EsrWeb.PubSub) do
          Phoenix.PubSub.unsubscribe(EsrWeb.PubSub, "directive_ack:" <> id)
        end

        Logger.warning(
          "feishu_chat_proxy: pending_media timeout id=#{id} " <>
            "session_id=#{state.session_id}"
        )

        {:noreply, %{state | pending_media: remaining}}
    end
  end

  # PR-24 step 2 — PTY ↔ Feishu boot bridge handlers.
  #
  # `:pty_stdout` arrives any time the wrapped claude process emits
  # bytes. While `boot_mode` is on we accumulate them and schedule a
  # debounced flush so a single TUI redraw turns into one Feishu
  # message instead of dozens. Once `cc_mcp_ready` arrives we stop
  # mirroring — cc_mcp's `notifications/claude/channel` path takes
  # over and the bridge is silent.
  @bridge_flush_ms 500

  # Max time to await a `submit_slash` result before returning :slash_timeout
  # to the caller. Slash commands typically complete in <100ms, but slow
  # commands (e.g. /session:new full pipeline spawn) can take seconds.
  @submit_slash_timeout_ms 30_000

  def handle_info({:pty_stdout, _data}, %{boot_mode: false} = state),
    do: {:noreply, state}

  def handle_info({:pty_stdout, data}, state) when is_binary(data) do
    new_buffer = state.pty_buffer <> data

    timer =
      case state.pty_flush_timer do
        nil -> Process.send_after(self(), :flush_pty_buffer, @bridge_flush_ms)
        existing -> existing
      end

    state =
      state
      |> Map.put(:pty_buffer, new_buffer)
      |> Map.put(:pty_flush_timer, timer)
      |> maybe_confirm_dev_channels()

    {:noreply, state}
  end

  # Once-only auto-confirm of claude's `--dangerously-load-development-
  # channels` dialog. We match against the buffer's stripped content
  # (ANSI codes mangle `Loading development channels` into segments
  # like `Loading[1Cdevelopment[1Cchannels`). The match string lives
  # AFTER strip so it's robust against whatever escape sequence claude
  # interleaves between words for layout. The first match writes "1\r"
  # to the PTY's stdin via erlexec — answering the dialog from inside
  # the BEAM, no external helper needed.
  defp maybe_confirm_dev_channels(%{dev_channels_confirmed: true} = state), do: state

  defp maybe_confirm_dev_channels(%{pty_buffer: buf, session_id: sid} = state) do
    stripped = Esr.AnsiStrip.strip(buf)

    if String.contains?(stripped, "Loading development channels") and
         String.contains?(stripped, "I am using this for local development") do
      Logger.info(
        "feishu_chat_proxy: auto-confirming dev-channels dialog session_id=#{sid}"
      )

      # Phase A.4b: PTY register key keys on actor_id. state.pty_actor_id
      # is resolved at init via resolve_pty_actor_id/1 (falls back to
      # session_id for AgentSpawner spawns where no InstanceRegistry row
      # exists — matches PtyProcess's `actor_id ||= session_id`).
      _ = Esr.Entity.PtyProcess.write(state.pty_actor_id, "1\r")
      %{state | dev_channels_confirmed: true}
    else
      state
    end
  end

  def handle_info(:flush_pty_buffer, state) do
    case Esr.AnsiStrip.strip(state.pty_buffer) do
      "" ->
        :ok

      stripped ->
        # Trim leading/trailing whitespace runs so chat doesn't show
        # 30-line blank gaps for cursor-only redraws.
        text = stripped |> String.trim() |> trim_redundant_blanks()

        if text != "" do
          forward_reply(text, nil, state)
        end
    end

    {:noreply, %{state | pty_buffer: "", pty_flush_timer: nil}}
  end

  def handle_info({:cc_mcp_ready, sid}, %{session_id: sid} = state) do
    # Final flush (in case there's anything still in the buffer) then
    # tear down the bridge. cc_mcp owns the channel from this point.
    state =
      case state.pty_flush_timer do
        nil ->
          state

        ref ->
          Process.cancel_timer(ref)
          send(self(), :flush_pty_buffer)
          %{state | pty_flush_timer: nil}
      end

    if Process.whereis(EsrWeb.PubSub) do
      # Phase A.4b: unsubscribe symmetrically with init's subscribe — the
      # PTY topic keys on actor_id, not session_id.
      Phoenix.PubSub.unsubscribe(EsrWeb.PubSub, "pty:" <> state.pty_actor_id)
    end

    Logger.info("feishu_chat_proxy: boot bridge handing off to cc_mcp session_id=#{sid}")

    {:noreply, %{state | boot_mode: false}}
  end

  def handle_info({:cc_mcp_ready, _other}, state), do: {:noreply, state}

  def handle_info(:send_default_winsize, state) do
    # No-op once cc_mcp_ready has flipped (xterm.js / cc_mcp owns the
    # terminal sizing from there) OR a browser already attached and
    # set its real viewport (the `:pty_attach` handler below cancels
    # this timer, but we double-check via the cleared ref).
    state = %{state | winsize_pending_ref: nil}

    if state.boot_mode do
      # Phase A.4b: PTY register key keys on actor_id post-Phase-A.4.
      _ = Esr.Entity.PtyProcess.resize(state.pty_actor_id, 120, 40)
    end

    {:noreply, state}
  end

  def handle_info({:pty_attach, sid}, %{session_id: sid} = state) do
    # Browser/websocat attached and is about to send its own resize.
    # Cancel the boot-bridge default-winsize timer so the operator's
    # actual viewport isn't clobbered.
    case Map.get(state, :winsize_pending_ref) do
      nil ->
        {:noreply, state}

      ref ->
        _ = Process.cancel_timer(ref)
        Logger.info("feishu_chat_proxy: cancelling default-winsize for sid=#{sid} (client attached)")
        {:noreply, %{state | winsize_pending_ref: nil}}
    end
  end

  def handle_info({:pty_attach, _other}, state), do: {:noreply, state}

  # PR-2 (2026-05-11 spec rev-3) — :pty_closed lifecycle handler.
  #
  # Pre-PR-2 there was no clause for `:pty_closed`. PtyProcess broadcasts
  # this on `pty:<actor_id>` when the wrapped claude process exits
  # (see Esr.Entity.PtyProcess.on_terminate/1). FCP subscribes to that
  # topic at init for the boot-bridge — so the message landed in FCP's
  # mailbox with no matching clause, triggering FunctionClauseError,
  # which crashed FCP, which (via :one_for_all on AgentInstanceSupervisor)
  # cascaded into the silent-drop incident: every subsequent inbound to
  # the chat saw no FCP and dropped on the unknown-actor lookup.
  #
  # The clause notifies the bound chat that the agent process died
  # (supervisor will restart it where possible) and stays alive itself.
  # No PID monitor / no plugin-specific PTY API — FCP is already
  # subscribed to the PubSub topic that delivers the close signal.
  def handle_info(:pty_closed, state) do
    notify_chat(state, %{
      kind: :downstream_died,
      message:
        "agent 进程退出;supervisor 会重启(如有可能)。" <>
          "如重复,运行 /session:end + /session:new 重建"
    })

    {:noreply, state}
  end

  # PR-2 (2026-05-11) — outbound helper for unsolicited FCP-originated
  # messages (lifecycle notifications, error surfaces). Uses the same
  # `forward_reply` path that CC-reply takes, so the same FAA routing /
  # adapter contract applies. The `payload.kind` is recorded for ops
  # log diagnosis; today only `:downstream_died` exists but future
  # lifecycle events (e.g. `:downstream_starting`) reuse the same shape.
  defp notify_chat(state, %{message: text} = payload) when is_binary(text) do
    require Logger

    Logger.info(
      "feishu_chat_proxy: notify_chat kind=#{inspect(payload[:kind])} " <>
        "session_id=#{state.session_id} chat_id=#{state.chat_id}"
    )

    # Reuse forward_reply (no reply_to_message_id — this is unsolicited,
    # not threaded to a specific inbound). forward_reply already routes
    # through emit_to_feishu_app_proxy → FAA → α-wire adapter, so the
    # plugin boundary stays intact: FCP never touches the Feishu HTTP
    # API directly; the adapter does.
    _ = forward_reply(text, nil, state)
    :ok
  end

  # M-1.5: deregister Index 2/3 entries on graceful shutdown. The
  # IndexWatcher monitor still cleans up if we crash before this hook
  # runs, so this is purely an optimization that closes the stale-entry
  # window between shutdown signal and DOWN delivery.
  @impl GenServer
  def terminate(_reason, %{session_id: sid} = state) when is_binary(sid) and sid != "" do
    _ =
      try do
        Esr.Entity.Registry.deregister_attrs("thread:" <> sid, %{
          session_id: sid,
          name: Map.get(state, :name) || ("fcp-" <> sid),
          role: @role
        })
      catch
        _, _ -> :ok
      end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Collapse runs of 3+ blank lines down to a single blank line so a
  # screen-clear + repaint doesn't fire 40 newlines into the chat.
  defp trim_redundant_blanks(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.chunk_by(&(String.trim(&1) == ""))
    |> Enum.flat_map(fn
      [maybe_blank | _] = chunk ->
        if String.trim(maybe_blank) == "", do: [""], else: chunk
    end)
    |> Enum.join("\n")
  end

  # Phase A.4b — PTY actor_id resolution.
  #
  # Post-Phase-A.4, PtyProcess registers under "pty:<actor_id>" and
  # broadcasts on the same topic. FCP needs the actor_id (not session_id)
  # for the boot-bridge subscribe + the auto-confirm/default-winsize
  # writes that go via the public PtyProcess.write/2 + resize/3 API.
  #
  # Resolution order:
  #   1. InstanceRegistry — primary agent's pty_actor_id from the
  #      `%Instance{}` ETS row. Used when /session:add-agent is the
  #      spawn path (multi-agent).
  #   2. session_id fallback — used when AgentSpawner (single-agent
  #      path) created the session: that path goes through
  #      Factory.spawn_peer without threading actor_id, and PtyProcess's
  #      init falls back to `actor_id ||= session_id`. Mirroring that
  #      fallback here keeps the lookup key consistent.
  #
  # The fallback also covers the boot-ordering race where FCP's init
  # runs BEFORE InstanceRegistry's `add_instance_and_spawn/2` ETS write
  # completes — though, as of A.4b, FCP is only spawned in the
  # single-agent AgentSpawner path, so the race window doesn't actually
  # exist in production today. The fallback is retained for forward
  # compatibility.
  defp resolve_pty_actor_id(session_id) do
    case Esr.Entity.Agent.InstanceRegistry.primary(session_id) do
      {:ok, name} ->
        case Esr.Entity.Agent.InstanceRegistry.pty_actor_id_for(session_id, name) do
          {:ok, aid} ->
            aid

          :not_found ->
            session_id
        end

      :not_found ->
        session_id
    end
  rescue
    # Esr.Entity.Agent.InstanceRegistry GenServer not running in some
    # isolated unit-test setups — fall back to session_id keying.
    _ -> session_id
  catch
    :exit, _ -> session_id
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp dispatch_tool_invoke("reply", args, req_id, channel_pid, state) do
    text = Map.get(args, "text") || ""
    chat_id = Map.get(args, "chat_id") || state.chat_id
    app_id = Map.get(args, "app_id") || state.app_id
    reply_to_msg_id = Map.get(args, "reply_to_message_id") || ""
    edit_msg_id = Map.get(args, "edit_message_id") || ""

    # PR-A T4: home-app vs cross-app. If the reply targets the same
    # app this FCP was spawned for, keep the existing pass-through
    # path (preserves un_react bookkeeping on `reply_to_message_id`).
    # Otherwise route to the target FAA's pid in Entity.Registry after
    # gating on `workspace:<target_ws>/msg.send` for the source
    # session's principal.
    if app_id == state.app_id do
      state =
        forward_reply_pass_through(text, Map.get(args, "reply_to_message_id"), state)

      reply_tool_result(channel_pid, req_id, true, %{"delivered" => true})
      state
    else
      if reply_to_msg_id != "" or edit_msg_id != "" do
        Logger.info(
          "FCP cross-app: stripping reply_to/edit ids " <>
            "(target_app=#{app_id}, source_app=#{state.app_id}, " <>
            "reply_to=#{inspect(reply_to_msg_id)}, edit=#{inspect(edit_msg_id)})"
        )
      end

      dispatch_cross_app_reply(chat_id, app_id, text, req_id, channel_pid, state)
    end
  end

  defp dispatch_tool_invoke("react", args, req_id, channel_pid, state) do
    _ =
      emit_to_feishu_app_proxy(
        %{
          "kind" => "react",
          "args" => %{
            "msg_id" => Map.get(args, "msg_id") || Map.get(args, "message_id") || "",
            "emoji_type" => Map.get(args, "emoji_type") || @default_react_emoji
          }
        },
        state
      )

    reply_tool_result(channel_pid, req_id, true, %{"reacted" => true})
    state
  end

  defp dispatch_tool_invoke("send_file", args, req_id, channel_pid, state) do
    # T12-comms-3g + Tasks 3.1+3.2 (spec 2026-05-08 D4 + §Outbound flow):
    # CC's MCP tool sends just `chat_id + file_path`. Before dispatching
    # on the α-wire we now:
    #   1. Infer media_type from the file extension
    #   2. Check the feishu plugin declares outbound for that media_type
    #   3. Content-address the bytes via Esr.Resource.Media.store
    # The α-wire shape (file_name + content_b64 + sha256) is UNCHANGED —
    # the Python sidecar contract stays uniform across all channel adapters.
    file_path = Map.get(args, "file_path") || ""
    chat_id = Map.get(args, "chat_id") || state.chat_id
    channel_adapter = Map.get(state, "channel_adapter", "feishu")

    case infer_media_type(file_path) do
      {:ok, media_type} ->
        with :ok <- check_outbound_capability(channel_adapter, media_type),
             {:ok, %{sha256: sha}} <-
               Esr.Resource.Media.store(media_type, file_path, %{
                 source_actor: "cc",
                 session_id: state.session_id,
                 chat_id: chat_id
               }),
             {:ok, file_name, content_b64, _sha2} <- read_file_for_send(file_path) do
          # Existing α-wire — UNCHANGED. The store call above handles
          # content-addressing + ref tracking; the α-wire delivers bytes
          # to the Python sidecar in the same shape it has always consumed
          # (Python adapter contract preserved per spec D4).
          _ =
            emit_to_feishu_app_proxy(
              %{
                "kind" => "send_file",
                "args" => %{
                  "chat_id" => chat_id,
                  "file_name" => file_name,
                  "content_b64" => content_b64,
                  "sha256" => sha
                }
              },
              state
            )

          reply_tool_result(channel_pid, req_id, true, %{"dispatched" => true})
        else
          {:error, :unsupported_outbound} ->
            reply_tool_result(channel_pid, req_id, false, nil, %{
              "type" => "unsupported_outbound",
              "kind" => to_string(media_type)
            })

          {:error, :unsupported_ext} ->
            reply_tool_result(channel_pid, req_id, false, nil, %{
              "type" => "unsupported_ext"
            })

          {:error, reason} ->
            Logger.warning(
              "feishu_chat_proxy: send_file failed path=#{inspect(file_path)} " <>
                "reason=#{inspect(reason)} session_id=#{state.session_id}"
            )

            reply_tool_result(channel_pid, req_id, false, nil, %{
              "type" => "store_or_read_failed",
              "detail" => inspect(reason)
            })
        end

      {:error, :no_extension} ->
        reply_tool_result(channel_pid, req_id, false, nil, %{
          "type" => "no_extension"
        })
    end

    state
  end

  # PR-4 (2026-05-11 default-agent + agent-driven-flow plan §5.2):
  # admin operations dispatched by the agent on behalf of the operator.
  # The agent calls `submit_slash(command="/agent:add type=cc name=helper")`;
  # we route the command through `Esr.Entity.SlashHandler.dispatch/2`
  # using `Esr.Slash.ReplyTarget.RawCollector` so we get back the raw
  # structured result (not the chat-rendered text that `ChatPid` produces).
  #
  # Per-call `Task`: SlashHandler dispatch can take 30s (e.g. /session:new
  # spawning agents); doing the `receive` inline would block FCP's
  # GenServer mailbox for that duration, backing up Feishu inbound and
  # tool-invoke traffic for the same session. The Task captures the
  # result and delivers the production-shape `tool_result` envelope back
  # on `channel_pid` via the standard `:push_envelope` flow.
  defp dispatch_tool_invoke("submit_slash", %{"command" => cmd_str},
                            req_id, channel_pid, state)
       when is_binary(cmd_str) do
    sid = state.session_id
    principal_id = state.principal_id

    Task.start(fn ->
      case run_submit_slash(sid, cmd_str, principal_id) do
        {:ok, result} ->
          reply_tool_result(channel_pid, req_id, true, result)

        {:error, err_map} ->
          reply_tool_result(channel_pid, req_id, false, nil, err_map)
      end
    end)

    state
  end

  defp dispatch_tool_invoke("submit_slash", _args, req_id, channel_pid, state) do
    # Schema enforces `command` required at the MCP layer; this clause
    # catches the unlikely case of a malformed args map (e.g. wrong type
    # for "command") without crashing the GenServer.
    reply_tool_result(channel_pid, req_id, false, nil, %{
      "type" => "invalid_args",
      "message" => "submit_slash requires args.command :: string"
    })

    state
  end

  defp dispatch_tool_invoke(unknown_tool, _args, req_id, channel_pid, state) do
    Logger.warning(
      "feishu_chat_proxy: unknown tool_invoke tool=#{inspect(unknown_tool)} " <>
        "session_id=#{state.session_id}"
    )

    reply_tool_result(
      channel_pid,
      req_id,
      false,
      nil,
      %{"type" => "unknown_tool", "message" => "FCP has no handler for #{unknown_tool}"}
    )

    state
  end

  # PR-4: resolve a session + originating chat, build a synthetic
  # inbound-shape envelope around `cmd_str`, dispatch it through
  # SlashHandler, await the raw result on `RawCollector`. Runs inside the
  # per-call Task spawned by the `"submit_slash"` clause above; the Task
  # owns the mailbox the RawCollector sends to (`caller: self()`).
  defp run_submit_slash(sid, cmd_str, principal_id) do
    case Esr.Uri.Compat.session_by_uuid(sid) do
      {:ok, session} ->
        case pick_origin_chat(session) do
          {:ok, chat} ->
            envelope = build_submit_slash_envelope(cmd_str, chat, principal_id)
            ref = make_ref()
            reply_target = {Esr.Slash.ReplyTarget.RawCollector, %{caller: self(), ref: ref}}
            _dispatch_ref = Esr.Entity.SlashHandler.dispatch(envelope, reply_target)

            receive do
              {:slash_raw, ^ref, {:ok, result}} ->
                {:ok, result}

              {:slash_raw, ^ref, {:error, reason}} ->
                {:error, %{"kind" => normalize_kind(reason)}}
            after
              @submit_slash_timeout_ms ->
                {:error, %{"kind" => "slash_timeout"}}
            end

          {:error, :no_attached_chat} ->
            {:error, %{"kind" => "no_attached_chat"}}
        end

      :not_found ->
        {:error, %{"kind" => "session_not_found"}}
    end
  end

  # PR-4: pick the originating chat for a submit_slash envelope. v1
  # picks the first attached chat (oldest by `attached_at`, since
  # Session.attached_chats is append-only — see resource/session/struct.ex
  # docstring). Multi-chat selection beyond v1 is spec §8 open work.
  defp pick_origin_chat(%{attached_chats: [first | _]}), do: {:ok, first}
  defp pick_origin_chat(%{attached_chats: []}), do: {:error, :no_attached_chat}

  # PR-4: assemble a synthetic msg_received envelope around `cmd_str`
  # so SlashHandler's existing inbound parser sees the same shape it
  # would see for a user-typed slash. `args.submitted_by` carries the
  # operator's principal id (used by capability checks downstream).
  defp build_submit_slash_envelope(cmd_str, %{chat_id: chat_id, app_id: app_id}, principal_id) do
    %{
      "id" => "submit-#{:erlang.unique_integer([:positive])}",
      "kind" => "event",
      "payload" => %{
        "args" => %{
          "content" => cmd_str,
          "msg_type" => "text",
          "chat_id" => chat_id,
          "app_id" => app_id,
          "submitted_by" => principal_id
        },
        "event_type" => "msg_received"
      },
      "source" => "esr://localhost/submit_slash",
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "type" => "event",
      "principal_id" => principal_id
    }
  end

  # PR-4: normalize SlashHandler error reasons into a stable string
  # `kind` for the MCP tool_result error map. Atoms become their
  # to_string form; structured maps keep `type` if present, else fall
  # back to inspect. Keeps the wire shape predictable for the agent's
  # error-translation logic.
  defp normalize_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_kind(reason) when is_binary(reason), do: reason
  defp normalize_kind(%{"type" => t}) when is_binary(t), do: t
  defp normalize_kind(other), do: inspect(other)

  # Infer media_type atom from the file extension. Image extensions map
  # to :image; any other recognised extension maps to :file; missing or
  # bare-dot extension returns {:error, :no_extension}.
  defp infer_media_type(path) do
    case path |> Path.extname() |> String.downcase() do
      "" -> {:error, :no_extension}
      "." -> {:error, :no_extension}
      ext when ext in [".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic"] -> {:ok, :image}
      _other -> {:ok, :file}
    end
  end

  # Check whether the named channel adapter plugin declares outbound
  # capability for the given media_type via Esr.Resource.Media.PluginRegistry.
  #
  # Normalization: `parse_channel_adapter/1` extracts the full adapter
  # family name from the proxy target (e.g. "feishu_app" from
  # "admin::feishu_app_adapter_<id>"). Plugin manifests use a shorter
  # canonical name ("feishu"). Normalize by stripping a trailing "_app"
  # suffix so "feishu_app" looks up as "feishu". If the normalized name
  # is also not registered, fall back to the original so the error message
  # stays meaningful.
  defp check_outbound_capability(plugin_name, media_type) do
    normalized =
      if String.ends_with?(plugin_name, "_app") do
        String.slice(plugin_name, 0, String.length(plugin_name) - 4)
      else
        plugin_name
      end

    lookup = if normalized != plugin_name, do: normalized, else: plugin_name

    if Esr.Resource.Media.PluginRegistry.supports?(lookup, :outbound, media_type) do
      :ok
    else
      {:error, :unsupported_outbound}
    end
  end

  # 30 MiB — the cheapest meaningful cap for the α in-band payload
  # before base64-blowup makes the channel envelope unwieldy. Feishu's
  # own /open-apis/im/v1/files limit is 30MB; matching it here means
  # we reject locally before paying the read+encode cost.
  @send_file_max_bytes 30 * 1024 * 1024

  # Read the file from disk and prepare the α wire-shape args. Returns
  # {:ok, file_name, content_b64, sha256} or {:error, reason}.
  #
  # Defence-in-depth (T12-comms-3o post-merge review):
  # - reject empty / non-absolute paths so a relative `../../etc/passwd`
  #   from a confused tool-call can't traverse out of cwd
  # - size cap before File.read to avoid blocking the GenServer on a
  #   100MiB+ read just to have the adapter reject it downstream
  # The trust boundary is still "CC has admin trust" — a fully
  # malicious CC can still read any path the BEAM user can; tighter
  # bounding to the session's workspace dir is tracked as follow-up.
  defp read_file_for_send(""), do: {:error, :empty_path}

  defp read_file_for_send(path) when is_binary(path) do
    cond do
      Path.type(path) != :absolute ->
        {:error, :path_not_absolute}

      String.contains?(path, "..") ->
        {:error, :path_contains_traversal}

      true ->
        with {:ok, %File.Stat{size: size}} when size <= @send_file_max_bytes <-
               File.stat(path),
             {:ok, bytes} <- File.read(path) do
          sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
          {:ok, Path.basename(path), Base.encode64(bytes), sha}
        else
          {:ok, %File.Stat{size: size}} -> {:error, {:too_large, size, @send_file_max_bytes}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # PR-A T4: cross-app dispatch. Three structured failure modes:
  #   * unknown_chat_in_app — Workspaces.Registry has no row for
  #     (chat_id, app_id); CC typed the wrong chat or the workspace
  #     mapping isn't loaded.
  #   * forbidden — principal lacks `workspace:<target_ws>/msg.send`.
  #   * unknown_app — no FeishuAppAdapter pid registered in
  #     Entity.Registry under "feishu_app_adapter_<app_id>".
  defp dispatch_cross_app_reply(chat_id, app_id, text, req_id, channel_pid, state) do
    case Esr.Uri.Compat.workspace_name_for_chat(chat_id, app_id) do
      {:ok, target_ws} ->
        perm = "workspace:#{target_ws}/msg.send"

        if Esr.Resource.Capability.has?(state.principal_id, perm) do
          dispatch_to_target_app(chat_id, app_id, text, req_id, channel_pid)
        else
          # Logger.info on every deny path — gives ops a deterministic
          # signal independent of the model's response, which scenario
          # 04 scrapes from esrd's stdout.log to detect cross-app
          # auth-gate behavior. The structured fields mirror the
          # tool_result error so log + wire stay symmetric.
          Logger.info(
            "FCP cross-app deny type=forbidden " <>
              "principal_id=#{inspect(state.principal_id)} " <>
              "app_id=#{inspect(app_id)} chat_id=#{inspect(chat_id)} " <>
              "workspace=#{inspect(target_ws)} perm=#{inspect(perm)}"
          )

          reply_tool_result(channel_pid, req_id, false, nil, %{
            "type" => "forbidden",
            "app_id" => app_id,
            "chat_id" => chat_id,
            "workspace" => target_ws,
            "message" => "principal #{state.principal_id} lacks #{perm}"
          })
        end

      :not_found ->
        Logger.info(
          "FCP cross-app deny type=unknown_chat_in_app " <>
            "principal_id=#{inspect(state.principal_id)} " <>
            "app_id=#{inspect(app_id)} chat_id=#{inspect(chat_id)}"
        )

        reply_tool_result(channel_pid, req_id, false, nil, %{
          "type" => "unknown_chat_in_app",
          "app_id" => app_id,
          "chat_id" => chat_id,
          "message" =>
            "no workspace mapping for (chat_id=#{chat_id}, app_id=#{app_id})"
        })
    end

    state
  end

  defp dispatch_to_target_app(chat_id, app_id, text, req_id, channel_pid) do
    case lookup_target_app_proxy(app_id) do
      {:ok, target_pid} ->
        send(
          target_pid,
          {:outbound,
           %{"kind" => "reply", "args" => %{"chat_id" => chat_id, "text" => text}}}
        )

        reply_tool_result(channel_pid, req_id, true, %{
          "dispatched" => true,
          "cross_app" => true
        })

      :not_found ->
        Logger.info(
          "FCP cross-app deny type=unknown_app " <>
            "app_id=#{inspect(app_id)} chat_id=#{inspect(chat_id)}"
        )

        reply_tool_result(channel_pid, req_id, false, nil, %{
          "type" => "unknown_app",
          "app_id" => app_id,
          "message" =>
            "no FeishuAppAdapter registered for app_id=#{inspect(app_id)}"
        })
    end
  end

  # FeishuAppAdapter peers register under
  # "feishu_app_adapter_<instance_id>" in Esr.Entity.Registry on init.
  defp lookup_target_app_proxy(app_id) when is_binary(app_id) do
    case Registry.lookup(Esr.Entity.Registry, "feishu_app_adapter_#{app_id}") do
      [{pid, _}] when is_pid(pid) -> {:ok, pid}
      _ -> :not_found
    end
  end

  # Internal helper: forward a reply without dropping on to the usual
  # `{:forward, [], state}` Peer.Stateful return — we're invoked from a
  # `handle_info/2` clause that already `:noreply`s afterwards.
  defp forward_reply_pass_through(text, reply_to_message_id, state) do
    case forward_reply(text, reply_to_message_id, state) do
      {:forward, _, ns} -> ns
      {:drop, _, ns} -> ns
    end
  end

  defp reply_tool_result(channel_pid, req_id, ok?, data, error \\ nil) do
    payload = %{
      "kind" => "tool_result",
      "req_id" => req_id,
      "ok" => ok?,
      "data" => data,
      "error" => error
    }

    send(channel_pid, {:push_envelope, payload})
  end

  # Task 2.4: handle non-text inbound (image/file/audio) by dispatching
  # to Esr.Resource.Media.Inbound. The capability check is synchronous
  # (in-process registry lookup), but the actual `download_file`
  # directive is now fire-and-forget — its directive_ack arrives later
  # via `handle_info({:directive_ack, ...})`, which resumes the flow by
  # popping the matching `:pending_media` entry and dispatching
  # `forward_media_to_cc/3`.
  #
  # Pre-2026-05-09 this path used `build_directive_fn/1` and a blocking
  # `receive ... after timeout`, stalling the GenServer mailbox for up
  # to 30 s on every non-text inbound. Concurrent text replies + tool
  # invokes for the same session were delayed that long.
  @pending_media_timeout_ms 30_000

  defp do_handle_non_text_inbound(envelope, args, kind, _meta, state) do
    chat_id = args["chat_id"] || state.chat_id

    inbound = %{
      msg_type: kind,
      adapter_msg: %{
        "msg_id" => args["msg_id"] || args["message_id"] || "",
        "file_key" => args["file_key"] || "",
        "file_name" => args["file_name"] || "",
        "msg_type" => kind,
        "chat_id" => chat_id
      },
      meta: %{
        chat_id: chat_id,
        sender_id: envelope["principal_id"] || args["sender_id"] || "",
        source_plugin: "feishu",
        target_plugin: "claude_code"
      }
    }

    case Esr.Resource.Media.Inbound.handle(inbound) do
      {:directive, action, args_map, ctx} ->
        id =
          "d-" <>
            (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))

        directive = %{
          "kind" => "directive",
          "id" => id,
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "type" => "directive",
          "payload" => %{
            "adapter" => "feishu",
            "action" => action,
            "args" => args_map
          }
        }

        # Subscribe BEFORE the emit so a fast adapter ack lands in our
        # mailbox even if it's processed before send/2 returns.
        if Process.whereis(EsrWeb.PubSub) do
          Phoenix.PubSub.subscribe(EsrWeb.PubSub, "directive_ack:" <> id)
        end

        case emit_to_feishu_app_proxy(directive, state) do
          :ok ->
            Process.send_after(self(), {:pending_media_timeout, id}, @pending_media_timeout_ms)

            new_pending =
              Map.put(state.pending_media, id, Map.put(ctx, :envelope, envelope))

            {:ok, %{state | pending_media: new_pending}}

          {:drop, reason} ->
            if Process.whereis(EsrWeb.PubSub) do
              Phoenix.PubSub.unsubscribe(EsrWeb.PubSub, "directive_ack:" <> id)
            end

            Logger.warning(
              "feishu_chat_proxy: emit directive failed " <>
                "reason=#{inspect(reason)} session_id=#{state.session_id}"
            )

            {:ok, state}
        end

      {:error, :unsupported_kind} ->
        Esr.Entity.CapGuard.media_unsupported_dm(envelope, kind)

        Logger.info(
          "feishu_chat_proxy: media kind=#{inspect(kind)} not supported by cc — DM sent",
          session_id: state.session_id
        )

        {:ok, state}
    end
  end

  # Forward a URI-shaped media envelope to the cc_process neighbor.
  # The envelope_out from Media.Inbound carries %{msg_type, content (URI), meta}.
  # We thread it as {:text, uri, enriched_meta} so cc_process sees the
  # URI as text content and the meta carries msg_type for handler routing.
  defp forward_media_to_cc(envelope_out, upstream_meta, state) do
    # Phase 7 (2026-05-10): thread `current_session_id` (see
    # forward_text_and_react/4 comment) so multi-session-per-instance
    # CCProcess routes the media reply back to this session.
    enriched_meta =
      Map.merge(upstream_meta, %{
        msg_type: envelope_out.msg_type,
        media_uri: envelope_out.content,
        current_session_id: state.session_id
      })

    case Esr.ActorQuery.list_by_role(state.session_id, :cc_process) do
      [pid | _] ->
        send(pid, {:text, envelope_out.content, enriched_meta})

      [] ->
        Logger.warning(
          "feishu_chat_proxy: media inbound but no cc_process found via ActorQuery " <>
            "session_id=#{state.session_id}"
        )
    end
  end

  # PR-9 T11b.6a: upstream tuple is now `{:text, text, meta}` (3-tuple)
  # so CCProcess has message_id/sender_id/thread_id for the notification
  # envelope. CCProcess accepts both the new 3-tuple and legacy 2-tuple
  # `{:text, text}` (for backward compat with any unit-test callers that
  # haven't been migrated yet).
  defp forward_text_and_react(text, _message_id, meta, state) do
    # PR-21λ 2026-05-01: react side-effect deleted — FAA already
    # emitted the universal `TYPING` (敲键盘) react when the inbound
    # arrived. Function name kept (callers below) but it now just
    # forwards to CC; the un_react still fires on CC's reply path
    # via FAA's `handle_downstream` watching for `reply_to_message_id`.
    # M-2.1: ActorQuery replaces state.neighbors. Multi-instance same
    # role (Q5.2) — pick the first; future fan-out hooks here.
    #
    # Phase 7 (2026-05-10): thread `current_session_id` into the meta
    # so CCProcess (which may be shared across multiple attached
    # sessions) routes its reply / send_input back to THIS session's
    # cli:channel/<sid> topic and *_chat_proxy. Without this key,
    # CCProcess falls back to its originating `state.session_id` and
    # every reply lands in the wrong chat for the secondary sessions.
    meta_with_sid = Map.put(meta, :current_session_id, state.session_id)

    case Esr.ActorQuery.list_by_role(state.session_id, :cc_process) do
      [pid | _] ->
        send(pid, {:text, text, meta_with_sid})
        {:forward, [], state}

      [] ->
        Logger.warning(
          "feishu_chat_proxy: non-slash text but no cc_process found via ActorQuery " <>
            "session_id=#{state.session_id}"
        )

        {:drop, :no_cc_process, state}
    end
  end

  # CC outbound reply path. Threads `reply_to_message_id` through the
  # outbound envelope so FAA's `handle_downstream` can un_react the
  # original inbound's universal "received" emoji (PR-21λ). When
  # `reply_to_message_id` is nil, FAA skips the un_react and just
  # broadcasts the reply.
  defp forward_reply(text, reply_to_message_id, state) do
    args = %{"chat_id" => state.chat_id, "text" => text}

    args =
      if is_binary(reply_to_message_id) and reply_to_message_id != "" do
        Map.put(args, "reply_to_message_id", reply_to_message_id)
      else
        args
      end

    case emit_to_feishu_app_proxy(%{"kind" => "reply", "args" => args}, state) do
      :ok -> {:forward, [], state}
      {:drop, reason} -> {:drop, reason, state}
    end
  end

  # D1: FeishuChatProxy's own outbound emit channel. We send directly
  # to the `feishu_app_proxy` neighbor as an `{:outbound, envelope}`
  # message — the same shape the CC :reply path already uses. The
  # FeishuAppAdapter downstream broadcasts to `adapter:feishu/<app_id>`
  # where the Python adapter_runner consumes it. This keeps all
  # Feishu-specific semantics (react / un_react) inside this Elixir
  # module without ever touching Entity.Server's tool-dispatch path —
  # react is no longer a CC MCP tool (PR-9 T5 D4).
  defp emit_to_feishu_app_proxy(envelope, state) do
    # M-2.1: ActorQuery replaces state.neighbors.
    #
    # FeishuAppProxy is a stateless Esr.Entity.Proxy module — it has no
    # init/1 and therefore never registers itself in the ActorQuery role
    # index. The FAA (Feishu inbound/outbound door) IS registered under
    # "feishu_app_adapter_<app_id>" in Esr.Entity.Registry (FAA init/1
    # lines 77-78). Fall back to that registry when ActorQuery returns []
    # so the directive reaches the FAA directly.
    case Esr.ActorQuery.list_by_role(state.session_id, :feishu_app_proxy) do
      [pid | _] ->
        send(pid, {:outbound, envelope})
        :ok

      [] ->
        faa_key = "feishu_app_adapter_#{state.app_id}"

        case Esr.Entity.Registry.lookup(faa_key) do
          {:ok, pid} ->
            send(pid, {:outbound, envelope})
            :ok

          :error ->
            Logger.warning(
              "feishu_chat_proxy: emit #{envelope["kind"]} but no feishu_app_proxy found " <>
                "via ActorQuery session_id=#{state.session_id} " <>
                "and no FAA at #{inspect(faa_key)}"
            )

            {:drop, :no_app_proxy_neighbor}
        end
    end
  end

end

defmodule Esr.Entities.FeishuChatProxy do
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

    base = %{
      session_id: session_id,
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
      neighbors: Map.get(args, :neighbors, []),
      proxy_ctx: ctx
      # PR-21λ 2026-05-01: `pending_reacts` removed — FAA owns the
      # universal react/un_react lifecycle now (PR-9 T5's per-FCP
      # bookkeeping was redundant once FAA went one-react-per-inbound).
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
      pty_flush_timer: nil
    })

    if Process.whereis(EsrWeb.PubSub) do
      Phoenix.PubSub.subscribe(EsrWeb.PubSub, "pty:" <> session_id)
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
      # PR-C C3 (2026-04-27 actor-topology-routing §5.1 path (a)): pass
      # the inbound `source` URI and `principal_id` through to
      # cc_process so its BGP-style reachable_set learning can pick
      # them up without modifying the envelope schema. Both fields
      # are nil-safe — pre-PR-C envelopes that didn't carry them still
      # produce valid meta maps.
      source: envelope["source"],
      principal_id: envelope["principal_id"] || args["principal_id"]
    }

    # PR-21κ Phase 6: slash detection moved upstream into the FAA's
    # handle_upstream gate — slashes never reach FCP anymore. FCP is
    # now purely "forward inbound text to the CC session".
    forward_text_and_react(text, message_id, meta, state)
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

  # PR-24 step 2 — PTY ↔ Feishu boot bridge handlers.
  #
  # `:pty_stdout` arrives any time the wrapped claude process emits
  # bytes. While `boot_mode` is on we accumulate them and schedule a
  # debounced flush so a single TUI redraw turns into one Feishu
  # message instead of dozens. Once `cc_mcp_ready` arrives we stop
  # mirroring — cc_mcp's `notifications/claude/channel` path takes
  # over and the bridge is silent.
  @bridge_flush_ms 500

  def handle_info({:pty_stdout, _data}, %{boot_mode: false} = state),
    do: {:noreply, state}

  def handle_info({:pty_stdout, data}, state) when is_binary(data) do
    new_buffer = state.pty_buffer <> data

    timer =
      case state.pty_flush_timer do
        nil -> Process.send_after(self(), :flush_pty_buffer, @bridge_flush_ms)
        existing -> existing
      end

    {:noreply, %{state | pty_buffer: new_buffer, pty_flush_timer: timer}}
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
      Phoenix.PubSub.unsubscribe(EsrWeb.PubSub, "pty:" <> sid)
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
      _ = Esr.Entities.PtyProcess.resize(state.session_id, 120, 40)
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
    # T12-comms-3g: CC's MCP tool sends just `chat_id + file_path`. The
    # feishu adapter's `_send_file` wire shape (spec §6.1) is α: base64
    # in-band with a sha256 check, needing `file_name + content_b64 +
    # sha256`. Do the read + hash + encode at the Elixir boundary so
    # the Python adapter's contract stays uniform across all channel
    # adapters (only they know how to talk to their platform).
    file_path = Map.get(args, "file_path") || ""
    chat_id = Map.get(args, "chat_id") || state.chat_id

    case read_file_for_send(file_path) do
      {:ok, file_name, content_b64, sha256} ->
        _ =
          emit_to_feishu_app_proxy(
            %{
              "kind" => "send_file",
              "args" => %{
                "chat_id" => chat_id,
                "file_name" => file_name,
                "content_b64" => content_b64,
                "sha256" => sha256
              }
            },
            state
          )

        reply_tool_result(channel_pid, req_id, true, %{"dispatched" => true})

      {:error, reason} ->
        Logger.warning(
          "feishu_chat_proxy: send_file read failed path=#{inspect(file_path)} " <>
            "reason=#{inspect(reason)} session_id=#{state.session_id}"
        )

        reply_tool_result(
          channel_pid,
          req_id,
          false,
          nil,
          %{"type" => "read_failed", "message" => inspect(reason)}
        )
    end

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
    case Esr.Workspaces.Registry.workspace_for_chat(chat_id, app_id) do
      {:ok, target_ws} ->
        perm = "workspace:#{target_ws}/msg.send"

        if Esr.Capabilities.has?(state.principal_id, perm) do
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
    case Keyword.get(state.neighbors, :cc_process) do
      pid when is_pid(pid) ->
        send(pid, {:text, text, meta})
        {:forward, [], state}

      _ ->
        Logger.warning(
          "feishu_chat_proxy: non-slash text but no cc_process neighbor " <>
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
    case Keyword.get(state.neighbors, :feishu_app_proxy) do
      pid when is_pid(pid) ->
        send(pid, {:outbound, envelope})
        :ok

      _ ->
        Logger.warning(
          "feishu_chat_proxy: emit #{envelope["kind"]} but no feishu_app_proxy neighbor " <>
            "session_id=#{state.session_id}"
        )

        {:drop, :no_app_proxy_neighbor}
    end
  end

end

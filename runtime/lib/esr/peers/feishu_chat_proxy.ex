defmodule Esr.Peers.FeishuChatProxy do
  @moduledoc """
  Per-Session Peer.Stateful: entry point for inbound Feishu messages
  into the Session. Detects slash commands (leading `/` in the first
  token) and short-circuits to the AdminSession's SlashHandler; all
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
  use Esr.Peer.Stateful
  use GenServer
  require Logger

  @default_react_emoji "EYES"

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl Esr.Peer
  def spawn_args(params) do
    %{
      chat_id: Esr.Peer.get_param(params, :chat_id) || "",
      thread_id: Esr.Peer.get_param(params, :thread_id) || ""
    }
  end

  @impl GenServer
  def init(args) do
    ctx = Map.get(args, :proxy_ctx, %{})

    base = %{
      session_id: Map.fetch!(args, :session_id),
      chat_id: Map.fetch!(args, :chat_id),
      thread_id: Map.fetch!(args, :thread_id),
      neighbors: Map.get(args, :neighbors, []),
      proxy_ctx: ctx,
      # PR-9 T5b: track message_ids we've emitted a `react` for so
      # T5c's un_react path can fire without a lookup. Map values are
      # the emoji_type that was reacted with (future v2 may un-react a
      # different emoji than the one reacted; v1 uses the same default).
      pending_reacts: %{}
    }

    # D1 new pattern — explicitly lift a ctx field into state under a
    # string key so downstream peers reading the thread-state map (e.g.
    # PeerServer.build_emit_for_tool) see a typed, named slot instead of
    # reaching into the opaque proxy_ctx blob. Fallback "feishu" matches
    # the top-level spawn_pipeline default (session_router.ex). String
    # key + mixed-key map requires Map.put (Elixir disallows `key:` /
    # `"key" =>` in the same literal).
    state = Map.put(base, "channel_adapter", Map.get(ctx, :channel_adapter) || "feishu")

    {:ok, state}
  end

  @impl Esr.Peer.Stateful
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
    meta = %{
      message_id: message_id,
      sender_id: args["sender_id"] || "",
      thread_id: args["thread_id"] || ""
    }

    cond do
      slash?(text) ->
        dispatch_slash(envelope, state)

      true ->
        forward_text_and_react(text, message_id, meta, state)
    end
  end

  # PR-9 T5c: CC's reply lands here via the cc_process neighbor (see
  # dispatch_action(:reply, ...) in cc_process.ex). If the CC reply
  # carries `reply_to_message_id`, un-react that message BEFORE
  # forwarding the reply text — keeps all Feishu-specific
  # react/un-react semantics inside FeishuChatProxy.
  @impl Esr.Peer.Stateful
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

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp dispatch_slash(envelope, state) do
    case Esr.AdminSessionProcess.slash_handler_ref() do
      {:ok, slash_pid} ->
        send(slash_pid, {:slash_cmd, envelope, self()})
        {:drop, :slash_dispatched, state}

      :error ->
        Logger.warning(
          "feishu_chat_proxy: slash received but no SlashHandler registered " <>
            "(session_id=#{state.session_id})"
        )

        {:drop, :no_slash_handler, state}
    end
  end

  # PR-9 T11b.6a: upstream tuple is now `{:text, text, meta}` (3-tuple)
  # so CCProcess has message_id/sender_id/thread_id for the notification
  # envelope. CCProcess accepts both the new 3-tuple and legacy 2-tuple
  # `{:text, text}` (for backward compat with any unit-test callers that
  # haven't been migrated yet).
  defp forward_text_and_react(text, message_id, meta, state) do
    case Keyword.get(state.neighbors, :cc_process) do
      pid when is_pid(pid) ->
        send(pid, {:text, text, meta})
        new_state = maybe_emit_react(message_id, state)
        {:forward, [], new_state}

      _ ->
        Logger.warning(
          "feishu_chat_proxy: non-slash text but no cc_process neighbor " <>
            "session_id=#{state.session_id}"
        )

        {:drop, :no_cc_process, state}
    end
  end

  defp maybe_emit_react("", state), do: state

  defp maybe_emit_react(message_id, state) when is_binary(message_id) do
    case emit_to_feishu_app_proxy(
           %{
             "kind" => "react",
             "args" => %{"msg_id" => message_id, "emoji_type" => @default_react_emoji}
           },
           state
         ) do
      :ok ->
        Map.update!(state, :pending_reacts, fn pr ->
          Map.put(pr, message_id, @default_react_emoji)
        end)

      {:drop, _reason} ->
        # Already logged inside emit_to_feishu_app_proxy; keep state clean
        # so a missing neighbor on react doesn't leave phantom pending
        # entries that would later trigger an un_react we can't fulfil.
        state
    end
  end

  defp maybe_emit_react(_, state), do: state

  # CC outbound reply path — un-react first (if we have a pending react
  # for the referenced message_id) then forward the reply text to the
  # feishu_app_proxy neighbor. When reply_to_message_id is nil (legacy
  # caller that didn't pass the optional field), skip the un-react and
  # forward the reply as-is — backward compat per PR-9 T5 D4.
  defp forward_reply(text, reply_to_message_id, state) do
    state = maybe_emit_un_react(reply_to_message_id, state)

    case emit_to_feishu_app_proxy(
           %{
             "kind" => "reply",
             "args" => %{"chat_id" => state.chat_id, "text" => text}
           },
           state
         ) do
      :ok -> {:forward, [], state}
      {:drop, reason} -> {:drop, reason, state}
    end
  end

  defp maybe_emit_un_react(nil, state), do: state

  defp maybe_emit_un_react(message_id, state) when is_binary(message_id) do
    case Map.get(state.pending_reacts, message_id) do
      nil ->
        # No pending react for this message_id — nothing to un-react.
        # This is the v1 "optimistic" policy: if CC references a
        # message we never reacted to (e.g. the user edited their
        # message, or the react emit failed silently), skip rather
        # than firing a best-effort DELETE that's very likely to 404.
        state

      emoji ->
        _ =
          emit_to_feishu_app_proxy(
            %{
              "kind" => "un_react",
              "args" => %{"msg_id" => message_id, "emoji_type" => emoji}
            },
            state
          )

        Map.update!(state, :pending_reacts, &Map.delete(&1, message_id))
    end
  end

  defp maybe_emit_un_react(_, state), do: state

  # D1: FeishuChatProxy's own outbound emit channel. We send directly
  # to the `feishu_app_proxy` neighbor as an `{:outbound, envelope}`
  # message — the same shape the CC :reply path already uses. The
  # FeishuAppAdapter downstream broadcasts to `adapter:feishu/<app_id>`
  # where the Python adapter_runner consumes it. This keeps all
  # Feishu-specific semantics (react / un_react) inside this Elixir
  # module without ever touching PeerServer's tool-dispatch path —
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

  defp slash?(text) do
    case String.trim_leading(text) do
      "/" <> _rest -> true
      _ -> false
    end
  end
end

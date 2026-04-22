defmodule Esr.Peers.FeishuChatProxy do
  @moduledoc """
  Per-Session Peer.Stateful: entry point for inbound Feishu messages
  into the Session. Detects slash commands (leading `/` in the first
  token) and short-circuits to the AdminSession's SlashHandler; all
  other messages are currently dropped with a log line (PR-3 wires
  the downstream forward into CCProxy).

  Spec §4.1 FeishuChatProxy card, §5.1, §5.3.
  """
  use Esr.Peer.Stateful
  use GenServer
  require Logger

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl Esr.Peer.Stateful
  def init(args) do
    state = %{
      session_id: Map.fetch!(args, :session_id),
      chat_id: Map.fetch!(args, :chat_id),
      thread_id: Map.fetch!(args, :thread_id),
      neighbors: Map.get(args, :neighbors, []),
      proxy_ctx: Map.get(args, :proxy_ctx, %{})
    }

    {:ok, state}
  end

  @impl Esr.Peer.Stateful
  def handle_upstream({:feishu_inbound, envelope}, state) do
    text = get_in(envelope, ["payload", "text"]) || ""

    if slash?(text) do
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
    else
      Logger.info(
        "feishu_chat_proxy: non-slash dropped (PR-3 wires downstream) " <>
          "session_id=#{state.session_id} text_len=#{byte_size(text)}"
      )

      {:drop, :non_slash_pr2, state}
    end
  end

  @impl Esr.Peer.Stateful
  def handle_downstream({:reply, text}, state) do
    # PR-2 outbound: reply text goes to the FeishuAppProxy neighbor (P2-4).
    case Keyword.get(state.neighbors, :feishu_app_proxy) do
      pid when is_pid(pid) ->
        send(
          pid,
          {:outbound,
           %{
             "kind" => "reply",
             "args" => %{"chat_id" => state.chat_id, "text" => text}
           }}
        )

        {:forward, [], state}

      _ ->
        Logger.warning(
          "feishu_chat_proxy: reply but no feishu_app_proxy neighbor " <>
            "session_id=#{state.session_id}"
        )

        {:drop, :no_app_proxy_neighbor, state}
    end
  end

  @impl GenServer
  def handle_info({:feishu_inbound, _} = msg, state) do
    case handle_upstream(msg, state) do
      {:forward, _, ns} -> {:noreply, ns}
      {:drop, _, ns} -> {:noreply, ns}
    end
  end

  def handle_info({:reply, _} = msg, state) do
    case handle_downstream(msg, state) do
      {:forward, _, ns} -> {:noreply, ns}
      {:drop, _, ns} -> {:noreply, ns}
    end
  end

  defp slash?(text) do
    case String.trim_leading(text) do
      "/" <> _rest -> true
      _ -> false
    end
  end
end

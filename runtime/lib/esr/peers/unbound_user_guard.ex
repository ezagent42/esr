defmodule Esr.Peers.UnboundUserGuard do
  @moduledoc """
  Inbound gate (PR-21w) — when an inbound carries a Feishu open_id
  that isn't bound to any esr user, DM the operator a `esr user
  bind-feishu` walkthrough back to the chat. Rate-limited per
  open_id (10 min). Only fires when the chat IS workspace-bound;
  otherwise `Esr.Peers.UnboundChatGuard` takes precedence so
  operators don't get pelted with two DMs.

  Extracted from `Esr.Peers.FeishuAppAdapter` by PR-21w. Symmetric
  to `Esr.Peers.UnboundChatGuard` — same migration rationale, same
  shape.

  ### Public API

  - `check(user_id, chat_id, app_id)` — atomic check-and-set.
    Returns `:passthrough` (user bound or pre-conditions absent),
    `{:emit, text}` (caller DMs the text), or `:rate_limited`
    (no DM, drop quietly).
  """

  @behaviour Esr.Role.Pipeline
  use GenServer

  @default_interval_ms 10 * 60 * 1000

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec check(String.t(), String.t(), String.t()) ::
          :passthrough | {:emit, String.t()} | :rate_limited
  def check(user_id, chat_id, app_id)
      when is_binary(user_id) and user_id != "" and
             is_binary(chat_id) and chat_id != "" and
             is_binary(app_id) and app_id != "" do
    with {:ok, _ws} <- Esr.Workspaces.Registry.workspace_for_chat(chat_id, app_id),
         registry_pid when is_pid(registry_pid) <- Process.whereis(Esr.Users.Registry),
         :not_found <- Esr.Users.Registry.lookup_by_feishu_id(user_id) do
      case GenServer.call(__MODULE__, {:note_emit?, user_id}) do
        :emit -> {:emit, user_guide_text(user_id)}
        :rate_limited -> :rate_limited
      end
    else
      _ -> :passthrough
    end
  end

  def check(_, _, _), do: :passthrough

  # ------------------------------------------------------------------
  # GenServer
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    {:ok, %{last_emit: %{}, interval_ms: interval_ms}}
  end

  @impl true
  def handle_call({:note_emit?, key}, _from, state) do
    now = :erlang.monotonic_time(:millisecond)
    last = Map.get(state.last_emit, key)

    if is_nil(last) or now - last >= state.interval_ms do
      {:reply, :emit, %{state | last_emit: Map.put(state.last_emit, key, now)}}
    else
      {:reply, :rate_limited, state}
    end
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp user_guide_text(user_id) do
    """
    👋 你的 Feishu 身份还没绑到 ESR 用户。先看一下已注册的 esr user：

      ./esr.sh --env=<prod|dev> user list

    然后跑：

      ./esr.sh --env=<prod|dev> user bind-feishu <esr_username> #{user_id}

    绑完之后给本 bot 发任意消息就会走 ESR 流程。

    你的 Feishu open_id 是 #{user_id}（复制即可）。

    （这条消息 10 分钟内不会重复发送。）
    """
  end
end

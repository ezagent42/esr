defmodule Esr.Entities.UnboundChatGuard do
  @moduledoc """
  Inbound gate (PR-21w) — drops Feishu inbound when the originating
  chat isn't bound to any workspace, and DMs a one-shot registration
  guide back to the chat instead. Rate-limited per chat (10 min).

  Without this gate, every inbound from an unregistered chat would
  fall through to `Esr.Scope.Router`, which silently maps unknown
  chats to `workspace="default"` — operators get no signal that their
  chat isn't configured, and traffic mysteriously lands in someone
  else's workspace. The gate emits a self-describing DM with the two
  registration options, then drops the inbound.

  Extracted from `Esr.Entities.FeishuAppAdapter` by PR-21w. Migration
  rationale: PR-21u/v formalized the `*Guard` suffix for inbound
  gates with their own rate-limit / TTL state. Moving the
  `guide_dm_last_emit` map out of FAA's GenServer state into a
  dedicated process also unifies rate-limit accounting across multiple
  FAA peers (previously each FAA tracked independently — a soft
  multi-FAA regression noted in the original inline comments).

  ### Public API

  - `check(chat_id, app_id, instance_id)` — atomic check-and-set.
    Returns `:passthrough` (workspace bound), `{:emit, text}` (caller
    DMs the text), or `:rate_limited` (no DM, drop quietly).
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
  def check(chat_id, app_id, instance_id)
      when is_binary(chat_id) and chat_id != "" and
             is_binary(app_id) and app_id != "" and
             is_binary(instance_id) do
    case Esr.Workspaces.Registry.workspace_for_chat(chat_id, app_id) do
      {:ok, _ws} ->
        :passthrough

      :not_found ->
        case GenServer.call(__MODULE__, {:note_emit?, {app_id, chat_id}}) do
          :emit -> {:emit, guide_text(chat_id, app_id, instance_id)}
          :rate_limited -> :rate_limited
        end
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

  defp guide_text(chat_id, app_id, _instance_id) do
    """
    👋 这个 chat 还没在 ESR 注册 workspace，所以收到的消息会被忽略。

    两种注册方式（任选其一）：

    A. 在本 chat 直接发 slash 命令（推荐 — 自动绑当前 chat）：

       /new-workspace <workspace_name>

       owner 缺省 = 你（已绑定的 esr user）；role / start_cmd 用默认值。
       PR-22 之后 workspace 不再绑特定 git 仓库——repo 是 per-session 的。

    B. 在 esr 仓库 CLI 里跑（注意 --env 选 prod 或 dev）：

       ./esr.sh --env=<prod|dev> workspace add <workspace_name> \\
           --owner <esr_username> \\
           --start-cmd scripts/esr-cc.sh \\
           --role dev \\
           --chat #{chat_id}:#{app_id}:dm

    注册后给本 bot 发：

      /new-session <workspace_name> name=<session_name> \\
          root=<主 git 仓库路径> cwd=<worktree 路径> worktree=<分支名>

    会话就会拉起来（每个 session 一个独立 worktree，从 origin/main fork）。

    （这条消息 10 分钟内不会重复发送。）
    """
  end
end

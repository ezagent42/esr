defmodule Esr.Commands.Doctor do
  @moduledoc """
  `/doctor` slash command — two modes:

    * default (`mode=chat`, the original) — per-chat operator help:
      user-binding + chat-binding status with bootstrap walk-through.
    * `mode=system` — runtime health snapshot (esrd_pid, users_loaded,
      workspaces_loaded, workers_tracked + workers list). Migrated from
      `EsrWeb.CliChannel.dispatch("cli:daemon/doctor", ...)`.

  Reads from args:
    * `mode` (optional, "chat" | "system" — default "chat")
    * `caller_principal_id` (Feishu open_id from envelope; chat mode only)
    * `chat_id` / `app_id` (chat mode only)

  Pre-PR-21κ the chat-mode body lived in `Esr.Entity.FeishuAppAdapter.doctor_text/3`.
  """

  use Esr.Commands.Meta

  command :doctor do
    slash         "/doctor"
    category      "诊断"
    description   "状态检查 + 卡在哪步的 bootstrap 步骤建议"
    permission    nil
    requires_user_binding      false
    requires_workspace_binding false

    arg :mode, required: false, default: "chat", doc: "chat | system"
  end

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"mode" => "system"}} = _cmd), do: {:ok, %{"text" => system_snapshot_text(), "data" => system_snapshot_data()}}

  def execute(%{"args" => args} = _cmd) do
    principal_id = Map.get(args, "caller_principal_id", "(unknown)")
    chat_id = Map.get(args, "chat_id", "(unknown)")
    app_id = Map.get(args, "app_id", "(unknown)")

    {user_line, user_ok} = check_user(principal_id)
    {chat_line, chat_ok, ws_name} = check_chat(chat_id, app_id)

    next_steps = next_steps_text(user_ok, chat_ok, ws_name, principal_id, app_id)

    text =
      """
      🩺 ESR 状态诊断

      #{user_line}
      #{chat_line}

      #{String.trim(next_steps)}
      """

    {:ok, %{"text" => text}}
  end

  def execute(_cmd), do: {:ok, %{"text" => "🩺 (no args)"}}

  defp system_snapshot_data do
    workers = Esr.WorkerSupervisor.list()
    user_count = length(Esr.Entity.User.Registry.list())

    workspace_count =
      try do
        :esr_workspace_name_index
        |> Esr.Resource.Workspace.NameIndex.all()
        |> length()
      rescue
        _ -> 0
      end

    %{
      "esrd_pid" => System.pid() |> to_string(),
      "users_loaded" => user_count,
      "workspaces_loaded" => workspace_count,
      "workers_tracked" => length(workers),
      "workers" =>
        Enum.map(workers, fn {kind, name, id, pid} ->
          %{"kind" => to_string(kind), "name" => name, "id" => id, "pid" => pid}
        end)
    }
  end

  defp system_snapshot_text do
    data = system_snapshot_data()

    workers_lines =
      data["workers"]
      |> Enum.map(fn w -> "    - #{w["kind"]}/#{w["name"]} (#{w["id"]}) #{w["pid"]}" end)
      |> Enum.join("\n")

    """
    🩺 esrd runtime snapshot

      esrd_pid:           #{data["esrd_pid"]}
      users_loaded:       #{data["users_loaded"]}
      workspaces_loaded:  #{data["workspaces_loaded"]}
      workers_tracked:    #{data["workers_tracked"]}
    #{if workers_lines == "", do: "    (no workers)", else: workers_lines}
    """
    |> String.trim_trailing()
  end

  defp check_user(principal_id) do
    if Process.whereis(Esr.Entity.User.Registry) do
      case Esr.Entity.User.Registry.lookup_by_feishu_id(principal_id) do
        {:ok, username} ->
          {"  ✅ 用户身份: 已绑定 esr user `#{username}`", true}

        :not_found ->
          {"  ❌ 用户身份: 未绑定 (你的 open_id: `#{principal_id}`)", false}
      end
    else
      {"  ⚠️ 用户身份: Esr.Entity.User.Registry 未运行", false}
    end
  end

  defp check_chat(chat_id, app_id) do
    case Esr.Resource.Workspace.Registry.workspace_for_chat(chat_id, app_id) do
      {:ok, ws} -> {"  ✅ Chat 绑定: workspace `#{ws}`", true, ws}
      :not_found -> {"  ❌ Chat 绑定: 未绑定任何 workspace", false, nil}
    end
  end

  defp next_steps_text(false, _chat_ok, _ws, principal_id, _app_id) do
    """
    ## 下一步：先绑定 esr user

    在终端跑（zero-config bootstrap：第一个 user_add 自动 admin）：

      esr exec user_add --name=<your_name>
      esr exec feishu_bind --name=<your_name> --feishu_user_id=#{principal_id}

    `user_add` 会通过 sentinel bypass + auto-admin 自动给新用户 grant
    `*` 全部 cap，并写 `operator.json` 让 CLI 后续命令自动用这个身份。
    `feishu_bind` 把当前 Feishu open_id 绑到 esr user。

    完整流程见 docs/guides/operator-bootstrap-journey.md。
    """
  end

  defp next_steps_text(true, false, _ws, _principal_id, _app_id) do
    """
    ## 下一步：在本 chat 创建 / 绑定 workspace + 起 session

    直接在这个 chat 里发：

      /workspace:new name=<workspace_name>

    或绑定已有 workspace 到当前 chat：

      /workspace:bind-chat name=<workspace_name>

    然后起 session（首次会自动用 user-default workspace，可省略 workspace=）：

      /session:new name=<session_name>

    再加一个 cc agent + 拿 TUI URL：

      /agent:add type=cc name=<agent_name>
      /claude_code:tui name=<agent_name>
    """
  end

  defp next_steps_text(true, true, ws_name, _principal_id, _app_id) do
    """
    ## 状态健康 ✅

    Workspace `#{ws_name}` 已绑。可用：

      /session:new name=<session_name>
      /session:list
      /session:end session=<uuid>
      /agent:add type=cc name=<agent_name>
      /claude_code:tui name=<agent_name>     # → 浏览器 TUI URL
    """
  end

  # env_hint/1 was used by the legacy `esr --env=<prod|dev> feishu bind ...`
  # text rendered before the 2026-05-09 grammar refresh. Post-refresh the
  # CLI uses operator.json + the kind-form `esr exec feishu_bind` (no
  # --env flag), so this helper has no callers. Kept here as dead code
  # for one PR cycle to avoid cross-cutting cleanup; removable in any
  # follow-up sweep.
end

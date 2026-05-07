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
    * `principal_id` (Feishu open_id from envelope; chat mode only)
    * `chat_id` / `app_id` (chat mode only)

  Pre-PR-21κ the chat-mode body lived in `Esr.Entity.FeishuAppAdapter.doctor_text/3`.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"mode" => "system"}} = _cmd), do: {:ok, %{"text" => system_snapshot_text(), "data" => system_snapshot_data()}}

  def execute(%{"args" => args} = _cmd) do
    principal_id = Map.get(args, "principal_id", "(unknown)")
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

  defp next_steps_text(false, _chat_ok, _ws, principal_id, app_id) do
    """
    ## 下一步：先绑定 esr user

    在终端跑：

      esr --env=#{env_hint(app_id)} user list
      esr --env=#{env_hint(app_id)} user bind-feishu <esr_user> #{principal_id}

    这会顺带 grant `workspace.create` / `session:default/create` 等 4 个
    基础 cap，你之后就能在 chat 里直接发 slash 命令。

    需要全权限（admin）的话：

      esr --env=#{env_hint(app_id)} cap grant #{principal_id} admin
    """
  end

  defp next_steps_text(true, false, _ws, _principal_id, _app_id) do
    """
    ## 下一步：在本 chat 创建 workspace

    直接在这个 chat 里发：

      /new-workspace <workspace_name>

    自动绑当前 chat。然后：

      /new-session <workspace_name> name=<session_name> \\
          root=<主 git 仓库路径> \\
          worktree=<分支名>

    worktree 检出路径自动派生为 `<root>/.worktrees/<分支名>`。
    """
  end

  defp next_steps_text(true, true, ws_name, _principal_id, _app_id) do
    """
    ## 状态健康 ✅

    Workspace `#{ws_name}` 已绑。可用：

      /new-session #{ws_name} name=<session_name> \\
          root=<repo> worktree=<分支>
      /sessions
      /end-session <name>

    worktree 检出路径自动派生为 `<root>/.worktrees/<分支>`。
    """
  end

  defp env_hint("esr_dev_helper"), do: "dev"
  defp env_hint("esr_helper"), do: "prod"
  defp env_hint(_), do: "<prod|dev>"
end

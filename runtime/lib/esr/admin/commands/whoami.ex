defmodule Esr.Admin.Commands.Whoami do
  @moduledoc """
  `/whoami` slash command — shows operator identity + chat / workspace
  binding state (PR-21κ).

  Reads from args:
    * `principal_id` (Feishu open_id from envelope)
    * `chat_id`
    * `app_id`

  Pre-PR-21κ this was `Esr.Peers.FeishuAppAdapter.whoami_text/3`.
  Same logic, lifted into a Command module so the SlashHandler can
  invoke it via the yaml-driven dispatch table.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => args} = _cmd) do
    principal_id = Map.get(args, "principal_id", "(unknown)")
    chat_id = Map.get(args, "chat_id", "(unknown)")
    app_id = Map.get(args, "app_id", "(unknown)")

    user_resolved =
      if Process.whereis(Esr.Users.Registry) do
        case Esr.Users.Registry.lookup_by_feishu_id(principal_id) do
          {:ok, username} -> "esr user: #{username}"
          :not_found -> "未绑定 (open_id: #{principal_id})"
        end
      else
        "(registry 未运行)"
      end

    workspace =
      case Esr.Workspaces.Registry.workspace_for_chat(chat_id, app_id) do
        {:ok, ws} -> ws
        :not_found -> "(无)"
      end

    text = """
    🪪 你的 ESR 身份

    open_id: #{principal_id}
    esr 用户: #{user_resolved}
    chat_id: #{chat_id}
    app_id (instance): #{app_id}
    workspace: #{workspace}
    """

    {:ok, %{"text" => text}}
  end

  def execute(_cmd), do: {:ok, %{"text" => "🪪 (no args)"}}
end

defmodule Esr.Commands.Workspace.Describe do
  @moduledoc """
  `/workspace describe` slash / admin-queue command — operator-facing
  view of the security-filtered workspace data shape sourced from
  `Esr.Resource.Workspace.Describe`.

  Migrated from `EsrWeb.CliChannel.dispatch("cli:workspaces/describe", ...)`.
  """

  use Esr.Commands.Meta

  command :workspace_describe do
    slash         "/workspace:describe"
    category      "Workspace"
    description   "显示 workspace 的安全过滤后视图"
    permission    "session.list"
    requires_user_binding      true
    requires_workspace_binding false

    arg :workspace, required: true, doc: "workspace 名"

    error :invalid_args,      "/workspace describe requires args.workspace"
    error :unknown_workspace, "no workspace %{workspace}"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"workspace" => ws_name}})
      when is_binary(ws_name) and ws_name != "" do
    case Esr.Resource.Workspace.Describe.describe(ws_name) do
      {:ok, data} ->
        {:ok, %{"text" => format(data), "data" => data}}

      {:error, :unknown_workspace} ->
        Render.error(__MODULE__.command_meta(), :unknown_workspace, %{workspace: ws_name})
    end
  end

  def execute(_),
    do: Render.error(__MODULE__.command_meta(), :invalid_args)

  defp format(%{"current_workspace" => current}) do
    chats =
      (current["chats"] || [])
      |> Enum.map(fn chat ->
        "    - #{chat["chat_id"] || "?"} #{chat["kind"] || "?"} app=#{chat["app_id"] || "?"}"
      end)
      |> Enum.join("\n")

    """
    workspace: #{current["name"]}
      role: #{current["role"]}
      chats:
    #{if chats == "", do: "    (none)", else: chats}
      metadata: #{inspect(current["metadata"] || %{})}
    """
    |> String.trim_trailing()
  end
end

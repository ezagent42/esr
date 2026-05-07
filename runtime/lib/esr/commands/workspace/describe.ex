defmodule Esr.Commands.Workspace.Describe do
  @moduledoc """
  `/workspace describe` slash / admin-queue command — operator-facing
  view of the security-filtered workspace data shape that
  `describe_topology` returns to the LLM. Same source of truth
  (`Esr.Resource.Workspace.Describe`) so what operators see is what
  the LLM sees.

  Migrated from `EsrWeb.CliChannel.dispatch("cli:workspaces/describe", ...)`.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"workspace" => ws_name}})
      when is_binary(ws_name) and ws_name != "" do
    case Esr.Resource.Workspace.Describe.describe(ws_name) do
      {:ok, data} ->
        {:ok, %{"text" => format(data), "data" => data}}

      {:error, :unknown_workspace} ->
        {:error,
         %{"type" => "unknown_workspace", "message" => "no workspace #{ws_name}"}}
    end
  end

  def execute(_),
    do:
      {:error,
       %{
         "type" => "invalid_args",
         "message" => "/workspace describe requires args.workspace"
       }}

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

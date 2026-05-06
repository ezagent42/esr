defmodule Esr.Commands.Workspace.List do
  @moduledoc """
  `/workspace list` slash — enumerate every workspace in the registry
  (ESR-bound + repo-bound). Read-only.

  Returns a YAML-shaped text envelope with workspace enumeration:
  - Empty registry → "no workspaces registered"
  - Non-empty → YAML list under `text` field with fields:
    name, id, owner, folders (count), chats (count),
    location (esr:path or repo:path), transient boolean

  Output structure (success):
      {:ok, %{"text" => "workspaces:\n  - name: ...\n    id: ...\n    ..."}}

  Empty case:
      {:ok, %{"text" => "no workspaces registered"}}
  """

  @behaviour Esr.Role.Control

  alias Esr.Resource.Workspace.{Struct, Registry}

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(_cmd) do
    text =
      case Registry.list_all() do
        [] -> "no workspaces registered"
        workspaces -> render_yaml(workspaces)
      end

    {:ok, %{"text" => text}}
  end

  defp render_yaml(workspaces) do
    rows =
      workspaces
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&render_row/1)

    yaml_header = "ok: true\ndata:\n  workspaces:"
    yaml_items = Enum.join(rows, "")

    yaml_header <> yaml_items
  end

  defp render_row(%Struct{} = ws) do
    """
    \n    - name: #{ws.name}
      id: #{ws.id}
      owner: #{ws.owner}
      folders: #{length(ws.folders)}
      chats: #{length(ws.chats)}
      location: #{format_location(ws.location)}
      transient: #{ws.transient}
    """
  end

  defp format_location({:esr_bound, dir}), do: "esr:#{dir}"
  defp format_location({:repo_bound, repo}), do: "repo:#{repo}"
  defp format_location(_), do: "unknown"
end

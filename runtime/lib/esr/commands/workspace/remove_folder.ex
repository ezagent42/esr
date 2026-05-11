defmodule Esr.Commands.Workspace.RemoveFolder do
  @moduledoc """
  `/workspace remove-folder` slash — remove a folder entry from a workspace.

  ## Args

      args: %{
        "name" => "esr-dev",    # required
        "path" => "/abs/path"   # required, must already be in ws.folders
      }

  ## Result

      {:ok,  %{"name" => ws_name, "id" => uuid, "removed" => "/abs/path", "folders" => remaining}}
      {:error, %{"type" => "invalid_args" | "unknown_workspace" |
                            "folder_not_in_workspace" | "cannot_remove_root_folder", ...}}

  ## Root-folder protection

  Removing `folders[0]` from a repo-bound workspace raises `cannot_remove_root_folder`.
  Use `/workspace forget-repo` to detach a repo-bound workspace entirely.

  ESR-bound workspaces may remove any folder, including position 0.
  """

  use Esr.Commands.Meta

  command :workspace_remove_folder do
    slash         "/workspace:remove-folder"
    category      "Workspace"
    description   "从 workspace.folders[] 删一项（repo-bound 不能删 folders[0]，请用 /workspace:forget-repo）"
    permission    "workspace.create"
    requires_user_binding      true
    requires_workspace_binding false

    arg :name, required: true, doc: "workspace 名"
    arg :path, required: true, doc: "要删除的 folder 路径"

    error :invalid_args,             "workspace_remove_folder requires args.name and args.path"
    error :unknown_workspace,        "workspace %{name} not found"
    error :folder_not_in_workspace,  "path %{path} is not in this workspace's folders"
    error :cannot_remove_root_folder, "cannot remove the root folder of a repo-bound workspace; use /workspace forget-repo instead"
    error :cannot_remove_last_folder, "workspace %{name} 只剩 1 个 folder；用 /workspace:remove 删整个 workspace"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Resource.Workspace.{Struct, Registry, NameIndex}

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd)

  def execute(%{"args" => %{"name" => name, "path" => path}})
      when is_binary(name) and name != "" and is_binary(path) and path != "" do
    expanded = Path.expand(path)

    with {:ok, ws} <- lookup_struct_by_name(name),
         :ok <- validate_folder_in_workspace(ws, expanded),
         :ok <- validate_not_last_folder(ws),
         :ok <- validate_not_root_folder(ws, expanded),
         remaining = Enum.reject(ws.folders, fn f -> Path.expand(f.path) == expanded end),
         updated = %{ws | folders: remaining},
         :ok <- Registry.put(updated) do
      {:ok,
       %{
         "name" => ws.name,
         "id" => ws.id,
         "removed" => expanded,
         "folders" => serialise_folders(remaining)
       }}
    end
  end

  def execute(_) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end

  ## Internals ---------------------------------------------------------------

  defp validate_folder_in_workspace(%Struct{folders: folders}, expanded) do
    in_ws = Enum.any?(folders, fn f -> Path.expand(f.path) == expanded end)

    if in_ws do
      :ok
    else
      Render.error(__MODULE__.command_meta(), :folder_not_in_workspace, %{path: expanded})
    end
  end

  defp validate_not_root_folder(%Struct{location: {:repo_bound, _}, folders: [first | _]}, expanded) do
    if Path.expand(first.path) == expanded do
      Render.error(__MODULE__.command_meta(), :cannot_remove_root_folder, %{path: expanded})
    else
      :ok
    end
  end

  defp validate_not_root_folder(_ws, _expanded), do: :ok

  # ≥1-folder invariant (spec 2026-05-11 §4.1). Removing the only folder
  # would strand the workspace at 0 folders, which violates the invariant
  # JsonWriter would then reject. Refuse early — operator should call
  # /workspace:remove to delete the whole workspace instead.
  defp validate_not_last_folder(%Struct{folders: folders, name: name}) when length(folders) == 1 do
    Render.error(__MODULE__.command_meta(), :cannot_remove_last_folder, %{name: name})
  end

  defp validate_not_last_folder(_ws), do: :ok

  defp lookup_struct_by_name(name) do
    case NameIndex.id_for_name(:esr_workspace_name_index, name) do
      {:ok, id} ->
        case Registry.get_by_id(id) do
          {:ok, ws} -> {:ok, ws}
          :not_found -> workspace_not_found(name)
        end

      :not_found ->
        workspace_not_found(name)
    end
  end

  defp workspace_not_found(name) do
    Render.error(__MODULE__.command_meta(), :unknown_workspace, %{name: name})
  end

  defp serialise_folders(folders),
    do: Enum.map(folders, fn f -> %{"path" => f.path, "name" => Map.get(f, :name)} end)
end

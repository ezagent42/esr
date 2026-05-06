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

  @behaviour Esr.Role.Control

  alias Esr.Resource.Workspace.{Struct, Registry, NameIndex}

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd)

  def execute(%{"args" => %{"name" => name, "path" => path}})
      when is_binary(name) and name != "" and is_binary(path) and path != "" do
    expanded = Path.expand(path)

    with {:ok, ws} <- lookup_struct_by_name(name),
         :ok <- validate_folder_in_workspace(ws, expanded),
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
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "workspace_remove_folder requires args.name and args.path"
     }}
  end

  ## Internals ---------------------------------------------------------------

  defp validate_folder_in_workspace(%Struct{folders: folders}, expanded) do
    in_ws = Enum.any?(folders, fn f -> Path.expand(f.path) == expanded end)

    if in_ws do
      :ok
    else
      {:error,
       %{
         "type" => "folder_not_in_workspace",
         "path" => expanded,
         "message" => "path #{inspect(expanded)} is not in this workspace's folders"
       }}
    end
  end

  defp validate_not_root_folder(%Struct{location: {:repo_bound, _}, folders: [first | _]}, expanded) do
    if Path.expand(first.path) == expanded do
      {:error,
       %{
         "type" => "cannot_remove_root_folder",
         "path" => expanded,
         "message" =>
           "cannot remove the root folder of a repo-bound workspace; use /workspace forget-repo instead"
       }}
    else
      :ok
    end
  end

  defp validate_not_root_folder(_ws, _expanded), do: :ok

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
    {:error,
     %{
       "type" => "unknown_workspace",
       "name" => name,
       "message" => "workspace #{inspect(name)} not found"
     }}
  end

  defp serialise_folders(folders),
    do: Enum.map(folders, fn f -> %{"path" => f.path, "name" => Map.get(f, :name)} end)
end

defmodule Esr.Commands.Workspace.AddFolder do
  @moduledoc """
  `/workspace add-folder` slash — append a folder entry to a workspace.

  ## Args

      args: %{
        "name"        => "esr-dev",                   # required, workspace name
        "path"        => "/abs/path/to/another/repo", # required, abs path, must exist as dir
        "folder_name" => "tools"                      # optional, default Path.basename(path)
      }

  ## Result

      {:ok,  %{"name" => ws_name, "id" => uuid, "folders" => [%{"path", "name"}, ...]}}
      {:error, %{"type" => "invalid_args" | "folder_not_dir" | "folder_not_git_repo" |
                            "unknown_workspace" | "folder_already_added", ...}}
  """

  @behaviour Esr.Role.Control

  alias Esr.Resource.Workspace.{Struct, Registry, NameIndex}

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd)

  def execute(%{"args" => %{"name" => name, "path" => path} = args})
      when is_binary(name) and name != "" and is_binary(path) and path != "" do
    folder_name = args["folder_name"]

    with :ok <- validate_path_absolute(path),
         expanded = Path.expand(path),
         :ok <- validate_path_is_dir(expanded),
         :ok <- validate_path_is_git_repo(expanded),
         {:ok, ws} <- lookup_struct_by_name(name),
         :ok <- validate_not_duplicate(ws, expanded),
         new_folder = %{path: expanded, name: folder_name || Path.basename(expanded)},
         updated = %{ws | folders: ws.folders ++ [new_folder]},
         :ok <- Registry.put(updated) do
      {:ok,
       %{
         "name" => ws.name,
         "id" => ws.id,
         "folders" => serialise_folders(updated.folders)
       }}
    end
  end

  def execute(_) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "workspace_add_folder requires args.name and args.path"
     }}
  end

  ## Internals ---------------------------------------------------------------

  defp validate_path_absolute(path) do
    if Path.type(path) == :absolute do
      :ok
    else
      {:error,
       %{
         "type" => "invalid_args",
         "message" => "path must be an absolute path, got: #{inspect(path)}"
       }}
    end
  end

  defp validate_path_is_dir(expanded) do
    if File.dir?(expanded) do
      :ok
    else
      {:error, %{"type" => "folder_not_dir", "path" => expanded}}
    end
  end

  defp validate_path_is_git_repo(expanded) do
    if File.exists?(Path.join(expanded, ".git")) do
      :ok
    else
      {:error, %{"type" => "folder_not_git_repo", "path" => expanded}}
    end
  end

  defp validate_not_duplicate(%Struct{folders: folders}, expanded) do
    already_in =
      Enum.any?(folders, fn f ->
        Path.expand(f.path) == expanded
      end)

    if already_in do
      {:error,
       %{
         "type" => "folder_already_added",
         "path" => expanded,
         "message" => "path #{inspect(expanded)} is already in this workspace's folders"
       }}
    else
      :ok
    end
  end

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

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

  use Esr.Commands.Meta

  command :workspace_add_folder do
    slash         "/workspace:add-folder"
    category      "Workspace"
    description   "追加 folder 到 workspace.folders[]（path 必须是绝对路径且为 git repo；name= 缺省时 fallback 到 chat-current → user-default）"
    permission    "workspace.create"
    requires_user_binding      true
    requires_workspace_binding false

    arg :name,        required: false, doc: "workspace 名（缺省 fallback chat/user default）"
    arg :path,        required: true,  doc: "绝对路径，必须是 git repo"
    arg :folder_name, required: false, doc: "可选 display name，默认 Path.basename(path)"

    error :invalid_args,         "workspace_add_folder requires args.name and args.path"
    error :no_workspace_target,  "name= omitted but no chat-default and no user-default for submitter; pass name=<workspace> explicitly or run `/user:use workspace=<n>` first"
    error :folder_not_dir,       "path %{path} is not a directory"
    error :folder_not_git_repo,  "path %{path} is not a git repo"
    error :folder_already_added, "path %{path} is already in this workspace's folders"
    error :unknown_workspace,    "workspace %{name} not found"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Resource.Workspace.Struct

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd)

  # M-5/D5: name= is optional. When omitted, fall back through the
  # shared Resolve chain (chat-current → user-default → error).
  def execute(%{"args" => %{"path" => path} = args} = cmd)
      when is_binary(path) and path != "" and not is_map_key(args, "name") do
    case Esr.Commands.Workspace.Resolve.resolve_workspace_for_args(merge_submitter(cmd, args)) do
      {_tag, name} ->
        execute(%{cmd | "args" => Map.put(args, "name", name)})

      :no_match ->
        Render.error(__MODULE__.command_meta(), :no_workspace_target)
    end
  end

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
         :ok <- Esr.Uri.Compat.workspace_put(updated) do
      {:ok,
       %{
         "name" => ws.name,
         "id" => ws.id,
         "folders" => serialise_folders(updated.folders)
       }}
    end
  end

  def execute(_) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end

  ## Internals ---------------------------------------------------------------

  defp merge_submitter(cmd, args) do
    args
    |> Map.put_new("submitted_by", cmd["submitted_by"])
    |> Map.put_new("submitter_username", cmd["submitter_username"])
  end

  defp validate_path_absolute(path) do
    if Path.type(path) == :absolute do
      :ok
    else
      Render.error(__MODULE__.command_meta(), :invalid_args)
    end
  end

  defp validate_path_is_dir(expanded) do
    if File.dir?(expanded) do
      :ok
    else
      Render.error(__MODULE__.command_meta(), :folder_not_dir, %{path: expanded})
    end
  end

  defp validate_path_is_git_repo(expanded) do
    if File.exists?(Path.join(expanded, ".git")) do
      :ok
    else
      Render.error(__MODULE__.command_meta(), :folder_not_git_repo, %{path: expanded})
    end
  end

  defp validate_not_duplicate(%Struct{folders: folders}, expanded) do
    already_in =
      Enum.any?(folders, fn f ->
        Path.expand(f.path) == expanded
      end)

    if already_in do
      Render.error(__MODULE__.command_meta(), :folder_already_added, %{path: expanded})
    else
      :ok
    end
  end

  defp lookup_struct_by_name(name) do
    case Esr.Uri.Compat.uuid_for_workspace_name(name) do
      {:ok, id} ->
        case Esr.Uri.Compat.workspace_by_uuid(id) do
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

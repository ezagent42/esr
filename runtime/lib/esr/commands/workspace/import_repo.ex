defmodule Esr.Commands.Workspace.ImportRepo do
  @moduledoc """
  `/workspace import-repo` slash — register an existing
  `<repo>/.esr/workspace.json` so the repo's workspace becomes
  discoverable.

  ## Args

      args: %{ "path" => "/abs/path/to/repo" }

  ## Result

      {:ok, %{"path" => path, "name" => name, "id" => id, "action" => "imported"}}
      {:error, %{"type" => "...", ...}}
  """

  use Esr.Commands.Meta

  command :workspace_import_repo do
    slash         "/workspace:import-repo"
    category      "Workspace"
    description   "把一个带 .esr/workspace.json 的 git repo 加进 registered_repos.yaml；下次 esrd 启动会自动加载"
    permission    "workspace.create"
    requires_user_binding      true
    requires_workspace_binding false

    arg :path, required: true, doc: "绝对路径"

    error :invalid_args,          "workspace_import_repo requires args.path (absolute path)"
    error :path_not_dir,          "path %{path} is not a directory"
    error :not_a_workspace_repo,  "no .esr/workspace.json at %{path}"
    error :invalid_workspace_json, "invalid workspace.json at %{path}: %{detail}"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Resource.Workspace.{RepoRegistry, FileLoader}
  alias Esr.Paths

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd)

  def execute(%{"args" => %{"path" => path}})
      when is_binary(path) and path != "" do
    json_path = Path.join([path, ".esr", "workspace.json"])

    cond do
      Path.type(path) != :absolute ->
        Render.error(__MODULE__.command_meta(), :invalid_args)

      not File.dir?(path) ->
        Render.error(__MODULE__.command_meta(), :path_not_dir, %{path: path})

      not File.exists?(json_path) ->
        Render.error(__MODULE__.command_meta(), :not_a_workspace_repo, %{path: path})

      true ->
        with {:ok, ws} <- FileLoader.load(json_path, location: {:repo_bound, path}),
             :ok <- RepoRegistry.register(Paths.registered_repos_yaml(), path),
             :ok <- FileLoader.populate_uri_store() do
          {:ok,
           %{
             "path" => path,
             "name" => ws.name,
             "id" => ws.id,
             "action" => "imported"
           }}
        else
          {:error, reason} ->
            Render.error(__MODULE__.command_meta(), :invalid_workspace_json, %{
              path: path,
              detail: inspect(reason)
            })
        end
    end
  end

  def execute(_) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end
end

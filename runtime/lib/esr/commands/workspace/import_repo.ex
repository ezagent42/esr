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

  @behaviour Esr.Role.Control

  alias Esr.Resource.Workspace.{Registry, RepoRegistry, FileLoader}
  alias Esr.Paths

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd)

  def execute(%{"args" => %{"path" => path}})
      when is_binary(path) and path != "" do
    json_path = Path.join([path, ".esr", "workspace.json"])

    cond do
      Path.type(path) != :absolute ->
        {:error, %{"type" => "invalid_args", "message" => "path must be absolute"}}

      not File.dir?(path) ->
        {:error, %{"type" => "path_not_dir", "path" => path}}

      not File.exists?(json_path) ->
        {:error,
         %{
           "type" => "not_a_workspace_repo",
           "path" => path,
           "message" => "no .esr/workspace.json at #{path}"
         }}

      true ->
        with {:ok, ws} <- FileLoader.load(json_path, location: {:repo_bound, path}),
             :ok <- RepoRegistry.register(Paths.registered_repos_yaml(), path),
             :ok <- Registry.refresh() do
          {:ok,
           %{
             "path" => path,
             "name" => ws.name,
             "id" => ws.id,
             "action" => "imported"
           }}
        else
          {:error, reason} ->
            {:error,
             %{
               "type" => "invalid_workspace_json",
               "path" => path,
               "detail" => inspect(reason)
             }}
        end
    end
  end

  def execute(_) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "workspace_import_repo requires args.path"
     }}
  end
end

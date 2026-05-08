defmodule Esr.Commands.Workspace.ForgetRepo do
  @moduledoc """
  `/workspace forget-repo` slash — unregister a repo-bound workspace
  from registered_repos.yaml.

  Does NOT delete the on-disk .esr/workspace.json (caller can use
  `/workspace remove` for that). Idempotent — forgetting an unregistered
  path is `:ok` (action=already_forgotten).

  ## Args

      args: %{ "path" => "/abs/path/to/repo" }

  ## Result

      {:ok, %{"path" => path, "action" => "forgotten" | "already_forgotten"}}
      {:error, %{"type" => "...", ...}}
  """

  @behaviour Esr.Role.Control

  alias Esr.Resource.Workspace.{Registry, RepoRegistry}
  alias Esr.Paths

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd)

  def execute(%{"args" => %{"path" => path}})
      when is_binary(path) and path != "" do
    yaml_path = Paths.registered_repos_yaml()

    # Check current state
    case RepoRegistry.load(yaml_path) do
      {:ok, entries} ->
        if Enum.any?(entries, &(&1.path == path)) do
          # Path is registered; unregister it
          with :ok <- RepoRegistry.unregister(yaml_path, path),
               :ok <- Registry.refresh() do
            {:ok, %{"path" => path, "action" => "forgotten"}}
          end
        else
          # Path not registered; idempotent success
          {:ok, %{"path" => path, "action" => "already_forgotten"}}
        end

      {:error, reason} ->
        {:error,
         %{
           "type" => "registry_load_failed",
           "detail" => inspect(reason)
         }}
    end
  end

  def execute(_) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "workspace_forget_repo requires args.path"
     }}
  end
end

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

  use Esr.Commands.Meta

  command :workspace_forget_repo do
    slash         "/workspace:forget-repo"
    category      "Workspace"
    description   "从 registered_repos.yaml 移除 path（repo 内的 .esr/ 不动；如要删本地文件用 /workspace:remove）"
    permission    "workspace.create"
    requires_user_binding      true
    requires_workspace_binding false

    arg :path, required: true, doc: "绝对路径"

    error :invalid_args,         "workspace_forget_repo requires args.path"
    error :registry_load_failed, "registry load failed: %{detail}"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Resource.Workspace.{FileLoader, RepoRegistry}
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
               :ok <- FileLoader.populate_uri_store() do
            {:ok, %{"path" => path, "action" => "forgotten"}}
          end
        else
          # Path not registered; idempotent success
          {:ok, %{"path" => path, "action" => "already_forgotten"}}
        end

      {:error, reason} ->
        Render.error(__MODULE__.command_meta(), :registry_load_failed, %{detail: inspect(reason)})
    end
  end

  def execute(_) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end
end

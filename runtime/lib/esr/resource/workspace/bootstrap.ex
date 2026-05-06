defmodule Esr.Resource.Workspace.Bootstrap do
  @moduledoc """
  First-boot tasks for the workspace subsystem:

    * Delete legacy `workspaces.yaml` if present (operators must
      recreate workspaces via `/new-workspace` after the redesign).
    * Ensure a `default` workspace exists in the registry so
      `/new-session` without args resolves cleanly.

  Runs once at application boot, after Workspace.Registry is up.
  """

  use Task, restart: :transient
  require Logger

  def start_link(_), do: Task.start_link(__MODULE__, :run, [])

  def run do
    delete_legacy_yaml()
    ensure_default_workspace()
    :ok
  end

  defp delete_legacy_yaml do
    legacy_path = Path.join(Esr.Paths.runtime_home(), "workspaces.yaml")

    if File.exists?(legacy_path) do
      case File.rm(legacy_path) do
        :ok ->
          Logger.warning(
            "workspace.bootstrap: deleted legacy #{legacy_path}; " <>
              "recreate workspaces via /new-workspace"
          )

        {:error, reason} ->
          Logger.error(
            "workspace.bootstrap: failed to delete legacy #{legacy_path}: #{inspect(reason)}"
          )
      end
    end
  end

  defp ensure_default_workspace do
    case Esr.Resource.Workspace.Registry.get("default") do
      :error ->
        create_default_workspace()

      {:ok, _} ->
        :ok
    end
  rescue
    _ ->
      # Registry not running (e.g. during early test setups). Skip.
      :ok
  end

  defp create_default_workspace do
    dir = Esr.Paths.workspace_dir("default")
    File.mkdir_p!(dir)

    ws = %Esr.Resource.Workspace.Struct{
      id: UUID.uuid4(),
      name: "default",
      owner: System.get_env("ESR_BOOTSTRAP_PRINCIPAL_ID") || "admin",
      folders: [],
      agent: "cc",
      settings: %{},
      env: %{},
      chats: [],
      transient: false,
      location: {:esr_bound, dir}
    }

    case Esr.Resource.Workspace.Registry.put(ws) do
      :ok ->
        Logger.info(
          "workspace.bootstrap: created default workspace at #{dir} (id=#{ws.id})"
        )

      {:error, reason} ->
        Logger.error(
          "workspace.bootstrap: failed to put default workspace: #{inspect(reason)}"
        )
    end
  end
end

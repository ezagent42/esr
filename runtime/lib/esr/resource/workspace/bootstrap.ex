defmodule Esr.Resource.Workspace.Bootstrap do
  @moduledoc """
  First-boot tasks for the workspace subsystem (M-5 / D4):

    * Delete legacy `workspaces.yaml` if present.
    * If `ESR_BOOTSTRAP_PRINCIPAL_ID` is set AND that principal resolves
      to an esr user AND the user has no `default_workspace_id`, create
      `<username>-default` and link it via
      `Esr.Uri.Compat.set_default_workspace_for_user_name/2`.

  No literal `default` workspace is created. After M-5 the resolver
  chain (Esr.Commands.Workspace.Resolve) walks chat-default →
  user-default → error, so a per-user default workspace replaces the
  pre-M-5 system fallback.
  """

  use Task, restart: :transient
  require Logger

  def start_link(_), do: Task.start_link(__MODULE__, :run, [])

  def run do
    delete_legacy_yaml()
    ensure_bootstrap_user_default()
    :ok
  end

  defp delete_legacy_yaml do
    legacy_path = Path.join(Esr.Paths.runtime_home(), "workspaces.yaml")

    if File.exists?(legacy_path) do
      case File.rm(legacy_path) do
        :ok ->
          Logger.warning(
            "workspace.bootstrap: deleted legacy #{legacy_path}; recreate workspaces via /workspace:new"
          )

        {:error, reason} ->
          Logger.error(
            "workspace.bootstrap: failed to delete legacy #{legacy_path}: #{inspect(reason)}"
          )
      end
    end
  end

  defp ensure_bootstrap_user_default do
    with bootstrap_id when is_binary(bootstrap_id) and bootstrap_id != "" <-
           System.get_env("ESR_BOOTSTRAP_PRINCIPAL_ID"),
         {:ok, username} <- Esr.Uri.Compat.username_for_feishu_id(bootstrap_id),
         :not_found <- Esr.Uri.Compat.default_workspace_for_user_name(username) do
      create_user_default_for(username)
    else
      {:ok, _ws_id} ->
        # Already linked — idempotent skip.
        :ok

      _ ->
        :ok
    end
  rescue
    _ ->
      # URI store ETS table not running (e.g. early test setups). Skip.
      :ok
  end

  defp create_user_default_for(username) do
    ws_name = "#{username}-default"

    case Esr.Uri.Compat.uuid_for_workspace_name(ws_name) do
      {:ok, ws_id} ->
        # Workspace already exists (perhaps from a prior /user:add).
        # Just link it to the user-default.
        _ = Esr.Uri.Compat.set_default_workspace_for_user_name(username, ws_id)
        :ok

      :not_found ->
        ws_uuid = UUID.uuid4()
        dir = Esr.Paths.workspace_dir(ws_name)
        File.mkdir_p!(dir)

        # PR-1 ≥1-folder invariant (spec 2026-05-11 §4.1): ESR-bound
        # workspaces include the ESR-managed dir as their sole folder.
        ws = %Esr.Resource.Workspace.Struct{
          id: ws_uuid,
          name: ws_name,
          owner: username,
          folders: [%{path: dir, name: Path.basename(dir)}],
          agent: "cc",
          settings: %{},
          env: %{},
          chats: [],
          transient: false,
          location: {:esr_bound, dir}
        }

        case Esr.Uri.Compat.workspace_put(ws) do
          :ok ->
            _ = Esr.Uri.Compat.set_default_workspace_for_user_name(username, ws_uuid)

            Logger.info(
              "workspace.bootstrap: created #{ws_name} at #{dir} (id=#{ws_uuid}) + linked as user-default"
            )

            :ok

          {:error, reason} ->
            Logger.error(
              "workspace.bootstrap: failed to put #{ws_name}: #{inspect(reason)}"
            )

            :ok
        end
    end
  end
end

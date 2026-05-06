defmodule Esr.Commands.Workspace.Remove do
  @moduledoc """
  `/workspace remove` slash — permanently delete a workspace.

  ## Args

      args: %{
        "name"  => "esr-dev",   # required
        "force" => "true"       # optional; bypasses active-session guard
      }

  ## Behaviour

  ### ESR-bound workspaces
  The whole workspace directory (`<ESRD_HOME>/<inst>/workspaces/<name>/`) is
  deleted with `File.rm_rf!/1`. ESR owns that tree, so wholesale removal is safe.

  ### Repo-bound workspaces
  Only `<repo>/.esr/workspace.json` and `<repo>/.esr/topology.yaml` are removed.
  **NEVER `rm -rf <repo>/.esr/`** — the operator may have other files there
  (agents.yaml, env files, etc.) that must be preserved.
  The repo path is then unregistered from `registered_repos.yaml`.

  ### In both cases
  The workspace is dropped from the in-memory Registry (ETS + NameIndex).

  ## Active-sessions guard
  If any live sessions are attached to the workspace and `force` is not `true`,
  the command returns `{:error, %{"type" => "workspace_in_use", ...}}`.

  ## Result

      {:ok, %{"name" => name, "id" => uuid, "location" => "esr:<dir>" | "repo:<path>",
              "deleted_files" => [...]}}
      {:error, %{"type" => ..., ...}}

  ## Transitional note
  `active_sessions/1` currently stubs to `[]`. Phase 5.1 will wire a real lookup
  against `Esr.Resource.Workspace.SessionIndex` (or equivalent).
  """

  @behaviour Esr.Role.Control

  alias Esr.Paths
  alias Esr.Resource.Workspace.{Struct, Registry, NameIndex, RepoRegistry}

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd)

  def execute(%{"args" => %{"name" => name} = args})
      when is_binary(name) and name != "" do
    force = parse_bool(Map.get(args, "force", false))

    with {:ok, ws} <- lookup_struct_by_name(name),
         :ok <- check_active_sessions(ws.id, ws.name, force) do
      do_remove(ws)
    end
  end

  def execute(_) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "workspace_remove requires args.name (non-empty string)"
     }}
  end

  ## Internals ---------------------------------------------------------------

  # Active-sessions check.
  # Phase 5.1 will replace this with a real lookup against
  # Esr.Resource.Workspace.SessionIndex (or equivalent). Today no scope
  # tracks its workspace_id, so the answer is always [].
  defp active_sessions(workspace_id) do
    fn_override = Application.get_env(:esr, :workspace_active_sessions_fn, fn _ -> [] end)
    fn_override.(workspace_id)
  end

  defp check_active_sessions(id, name, force) do
    sessions = active_sessions(id)

    cond do
      sessions == [] or force ->
        :ok

      true ->
        {:error,
         %{
           "type" => "workspace_in_use",
           "name" => name,
           "sessions" => sessions,
           "message" =>
             "workspace #{inspect(name)} has #{length(sessions)} active session(s); " <>
               "use force=true to remove anyway"
         }}
    end
  end

  defp do_remove(%Struct{id: id, name: name, location: {:esr_bound, dir}} = _ws) do
    # ESR owns the entire directory tree; wholesale delete is safe.
    File.rm_rf!(dir)

    Registry.delete_by_id(id)

    {:ok,
     %{
       "name" => name,
       "id" => id,
       "location" => "esr:#{dir}",
       "deleted_files" => [dir]
     }}
  end

  defp do_remove(%Struct{id: id, name: name, location: {:repo_bound, repo}} = _ws) do
    ws_json_path = Paths.workspace_json_repo(repo)
    topology_yaml_path = Paths.topology_yaml_repo(repo)
    yaml_path = Paths.registered_repos_yaml()

    # Surgical delete — only the two ESR-managed files.
    # NEVER rm -rf <repo>/.esr/ — other operator files (agents.yaml, env, etc.)
    # must be preserved.
    deleted_files =
      [
        {ws_json_path, File.rm(ws_json_path)},
        {topology_yaml_path, File.rm(topology_yaml_path)}
      ]
      |> Enum.flat_map(fn
        {path, :ok} -> [path]
        # Ignore missing files (topology.yaml is optional)
        {_path, {:error, :enoent}} -> []
        # Re-raise unexpected errors
        {path, {:error, reason}} -> raise "Failed to delete #{path}: #{inspect(reason)}"
      end)

    RepoRegistry.unregister(yaml_path, repo)
    Registry.delete_by_id(id)

    {:ok,
     %{
       "name" => name,
       "id" => id,
       "location" => "repo:#{repo}",
       "deleted_files" => deleted_files
     }}
  end

  # Workspace lookup (mirrors edit.ex pattern)
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

  defp parse_bool("true"), do: true
  defp parse_bool(true), do: true
  defp parse_bool(_), do: false
end

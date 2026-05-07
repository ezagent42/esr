defmodule Esr.Paths do
  @moduledoc """
  Filesystem path helpers. Mirrors `py/src/esr/cli/paths.py` semantically.

  Reads `$ESRD_HOME` (default: `~/.esrd`) and `$ESR_INSTANCE` (default:
  `default`); composes runtime-state paths consistently across Elixir
  and Python sides.
  """

  def esrd_home, do: System.get_env("ESRD_HOME") || Path.expand("~/.esrd")

  def current_instance, do: System.get_env("ESR_INSTANCE", "default")

  def runtime_home, do: Path.join(esrd_home(), current_instance())

  def capabilities_yaml, do: Path.join(runtime_home(), "capabilities.yaml")
  def adapters_yaml, do: Path.join(runtime_home(), "adapters.yaml")
  def workspaces_yaml, do: Path.join(runtime_home(), "workspaces.yaml")
  def users_yaml, do: Path.join(runtime_home(), "users.yaml")
  def slash_routes_yaml, do: Path.join(runtime_home(), "slash-routes.yaml")
  def commands_compiled_dir, do: Path.join([runtime_home(), "commands", ".compiled"])
  def admin_queue_dir, do: Path.join(runtime_home(), "admin_queue")
  def plugins_yaml, do: Path.join(runtime_home(), "plugins.yaml")

  @doc "Top-level dir for ESR-bound workspaces. Per-instance."
  def workspaces_dir, do: Path.join(runtime_home(), "workspaces")

  @doc "Per-workspace dir for ESR-bound workspaces."
  def workspace_dir(name) when is_binary(name),
    do: Path.join(workspaces_dir(), name)

  @doc "Path to a workspace.json under the ESR-bound layout."
  def workspace_json_esr(name) when is_binary(name),
    do: Path.join(workspace_dir(name), "workspace.json")

  @doc "Path to workspace.json inside a user repo (repo-bound layout)."
  def workspace_json_repo(repo_path) when is_binary(repo_path),
    do: Path.join([repo_path, ".esr", "workspace.json"])

  @doc "Path to topology.yaml inside a user repo (project-shareable metadata)."
  def topology_yaml_repo(repo_path) when is_binary(repo_path),
    do: Path.join([repo_path, ".esr", "topology.yaml"])

  @doc "Per-instance registered repos list."
  def registered_repos_yaml,
    do: Path.join(runtime_home(), "registered_repos.yaml")

  @doc "Top-level sessions dir (per-instance, NOT per-workspace)."
  def sessions_dir, do: Path.join(runtime_home(), "sessions")

  @doc "Per-session state dir."
  def session_dir(sid) when is_binary(sid),
    do: Path.join(sessions_dir(), sid)

  @doc "JSON Schema file shipped in priv."
  def workspace_schema_v1, do: Application.app_dir(:esr, "priv/schemas/workspace.v1.json")

  @doc "Top-level dir for user-default workspaces. Per-instance."
  def users_dir, do: Path.join(runtime_home(), "users")

  @doc "Per-user dir. Keyed by user UUID (not username)."
  def user_dir(user_uuid) when is_binary(user_uuid),
    do: Path.join(users_dir(), user_uuid)

  @doc "Path to user.json for the given user UUID."
  def user_json(user_uuid) when is_binary(user_uuid),
    do: Path.join(user_dir(user_uuid), "user.json")

  @doc "Path to workspace.json for the user-default workspace."
  def user_workspace_json(user_uuid) when is_binary(user_uuid),
    do: Path.join([user_dir(user_uuid), ".esr", "workspace.json"])

  @doc "Path to user-layer plugins.yaml."
  def user_plugins_yaml(user_uuid) when is_binary(user_uuid),
    do: Path.join([user_dir(user_uuid), ".esr", "plugins.yaml"])

  @doc "Path to workspace-layer plugins.yaml inside a workspace root dir."
  def workspace_plugins_yaml(workspace_root) when is_binary(workspace_root),
    do: Path.join([workspace_root, ".esr", "plugins.yaml"])

  @doc "Path to user.v1.json schema shipped in priv."
  def user_schema_v1, do: Application.app_dir(:esr, "priv/schemas/user.v1.json")

  @doc "Path to session.json inside a session state dir."
  def session_json(uuid) when is_binary(uuid),
    do: Path.join(session_dir(uuid), "session.json")

  @doc "Path to .esr/ config overlay dir inside a session state dir."
  def session_workspace_dir(uuid) when is_binary(uuid),
    do: Path.join(session_dir(uuid), ".esr")

  @doc "Path to session.v1.json schema shipped in priv."
  def session_schema_v1, do: Application.app_dir(:esr, "priv/schemas/session.v1.json")
end

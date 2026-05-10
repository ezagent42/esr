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
  def workspaces_yaml, do: Path.join(runtime_home(), "workspaces.yaml")
  def users_yaml, do: Path.join(runtime_home(), "users.yaml")

  @doc """
  Active CLI operator state file (spec 2026-05-09 § 3.4). Written by
  `Esr.Commands.User.Add` (auto-admin path) and `Esr.Commands.User.Switch`;
  read by `Esr.Cli.Main.resolve_submitter/0`.
  """
  def operator_json, do: Path.join(runtime_home(), "operator.json")
  def slash_routes_yaml, do: Path.join(runtime_home(), "slash-routes.yaml")
  def commands_compiled_dir, do: Path.join([runtime_home(), "commands", ".compiled"])
  def admin_queue_dir, do: Path.join(runtime_home(), "admin_queue")
  def plugins_yaml, do: Path.join(runtime_home(), "plugins.yaml")

  @doc "Path to global-layer plugins.yaml (alias for plugins_yaml/0 — Phase 7)."
  def global_plugins_yaml, do: plugins_yaml()

  # ------------------------------------------------------------------
  # YAML layout v2 — per-thing directories
  # (spec: docs/superpowers/specs/2026-05-09-yaml-layout-v2-per-thing-directories.md)
  # ------------------------------------------------------------------

  @doc """
  Per-plugin global-layer config directory:
  `$ESRD_HOME/<inst>/plugins/<name>/`. Holds `config.yaml` + future
  per-plugin state.
  """
  def plugin_global_dir(name) when is_binary(name),
    do: Path.join([runtime_home(), "plugins", name])

  @doc """
  Per-plugin user-layer config directory:
  `$ESRD_HOME/<inst>/users/<uuid>/.esr/plugins/<name>/`.
  """
  def plugin_user_dir(name, user_uuid) when is_binary(name) and is_binary(user_uuid),
    do: Path.join([user_dir(user_uuid), ".esr", "plugins", name])

  @doc """
  Per-plugin workspace-layer config directory:
  `<workspace_root>/.esr/plugins/<name>/`.
  """
  def plugin_workspace_dir(name, workspace_root)
      when is_binary(name) and is_binary(workspace_root),
      do: Path.join([workspace_root, ".esr", "plugins", name])

  @doc "Top-level adapters directory: `$ESRD_HOME/<inst>/adapters/`."
  def adapters_dir, do: Path.join(runtime_home(), "adapters")

  @doc "Per-instance adapter directory: `$ESRD_HOME/<inst>/adapters/<name>/`."
  def adapter_dir(name) when is_binary(name),
    do: Path.join(adapters_dir(), name)

  @doc "Disabled-adapters parking lot: `$ESRD_HOME/<inst>/adapters/_disabled/`."
  def adapter_disabled_dir, do: Path.join(adapters_dir(), "_disabled")

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

  @doc "Path to user.v1.json schema shipped in priv."
  def user_schema_v1, do: Application.app_dir(:esr, "priv/schemas/user.v1.json")

  @doc "Path to session.json inside a session state dir."
  def session_json(uuid) when is_binary(uuid),
    do: Path.join(session_dir(uuid), "session.json")

  @doc "Path to .esr/ config overlay dir inside a session state dir."
  def session_workspace_dir(uuid) when is_binary(uuid),
    do: Path.join(session_dir(uuid), ".esr")

  @doc "Path to session.v2.json schema shipped in priv (Phase 7 hardcut)."
  def session_schema_v2, do: Application.app_dir(:esr, "priv/schemas/session.v2.json")

  @doc "Path to agent_instance.v2.json schema shipped in priv (Phase 7 hardcut)."
  def agent_instance_schema_v2, do: Application.app_dir(:esr, "priv/schemas/agent_instance.v2.json")

  @doc "Per-session agents directory: `<sessions_dir>/<sid>/agents/`."
  def session_agents_dir(sid) when is_binary(sid),
    do: Path.join(session_dir(sid), "agents")

  @doc "Path to a per-instance agent file at `sessions/<sid>/agents/<uuid>.json`."
  def agent_instance_json(sid, instance_uuid) when is_binary(sid) and is_binary(instance_uuid),
    do: Path.join(session_agents_dir(sid), instance_uuid <> ".json")

  # ------------------------------------------------------------------
  # SessionTemplate + Bundle (spec 2026-05-10, Phase 4)
  # ------------------------------------------------------------------

  @doc """
  In-tree bundles directory. Resolves to `runtime/lib/esr/bundles/`
  when esrd runs from compiled source. Each subdirectory is one
  bundle (`<name>/manifest.yaml` + `<name>/template.yaml`).

  Tests can override by passing an explicit path to
  `Esr.Bundle.Loader.load_all/1`.
  """
  def bundles_dir do
    # `__DIR__` for this file is `runtime/lib/esr/`; the bundles tree
    # lives at `runtime/lib/esr/bundles/` (sibling of plugins/) per the
    # moduledoc above. Same shape as Esr.Plugin.Loader's @default_root.
    #
    # 2026-05-10 (Phase 8 fix): pre-Phase-8 this was `Path.expand("../bundles", __DIR__)`
    # which evaluated to `runtime/lib/bundles/` — a non-existent dir.
    # The bug masked the in-tree feishu-cc bundle from production boot
    # (Bundle.Registry.list_all/0 returned []). Tests passed because
    # they pass an explicit `bundles_dir:` keyword. mix esr.gen_bundle_docs
    # exposed it because it walks the same path with no override.
    case :code.lib_dir(:esr) do
      {:error, _} ->
        Path.expand("bundles", __DIR__)

      lib_path when is_list(lib_path) ->
        # Compiled OTP app puts source at `<lib>/src` only if explicitly
        # bundled; the in-tree dev path is the moduledoc default. Use
        # the same dev path: walk down from this module's __DIR__.
        Path.expand("bundles", __DIR__)
    end
  end

  @doc """
  Operator-shipped session templates directory:
  `$ESRD_HOME/<inst>/session_templates/`. Standalone yaml files here
  are conflated manifest+template form per spec §5.3.
  """
  def session_templates_dir, do: Path.join(runtime_home(), "session_templates")
end

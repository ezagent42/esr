defmodule Esr.Commands.User.Add do
  @moduledoc """
  `user_add` admin-queue command — register a new esr user with no
  feishu binding. Mirrors Python `esr user add <name>`.

  Writes `users.yaml` directly; the file Watcher reloads
  `Esr.Entity.User.Registry` automatically.

  Also assigns a UUID v4, writes `users/<uuid>/user.json`, and
  populates `Esr.Entity.User.NameIndex` so that `/session:share
  user=<name>` resolves immediately without waiting for a file-watcher
  reload cycle.

  Phase B-3 of the Phase 3/4 finish (2026-05-05).
  fix/user-name-index-population: wire NameIndex on add.
  """

  use Esr.Commands.Meta

  command :user_add do
    slash         :none
    category      "Users"
    description   "注册新 esr user（写 users.yaml + user.json，建 user-default workspace；首位 user 自动 admin）"
    permission    "user.manage"
    requires_user_binding      false
    requires_workspace_binding false

    arg :name, required: true, doc: "username（ASCII 字母数字加 - / _）"

    error :invalid_args,    "%{detail}"
    error :already_exists,  "user '%{name}' already exists"
    error :write_failed,    "%{detail}"
  end

  @behaviour Esr.Role.Control

  require Logger

  alias Esr.Commands.Render
  alias Esr.Entity.User.NameIndex

  @username_regex ~r/^[A-Za-z0-9][A-Za-z0-9_\-]*$/

  @type result :: {:ok, map()} | {:error, map()}

  # Default for the last step's registry call. Tests inject a stub via
  # execute/2 opts to exercise rollback when the binding fails.
  @default_set_default_fn &Esr.Entity.User.Registry.set_default_workspace/2

  @spec execute(map()) :: result()
  def execute(cmd), do: execute(cmd, [])

  @spec execute(map(), keyword()) :: result()
  def execute(%{"args" => %{"name" => name}}, opts)
      when is_binary(name) and name != "" and is_list(opts) do
    cond do
      not Regex.match?(@username_regex, name) ->
        Render.error(__MODULE__.command_meta(), :invalid_args, %{
          detail:
            "username #{inspect(name)} must match #{inspect(Regex.source(@username_regex))} " <>
              "(ASCII alphanumeric, optionally with - and _)"
        })

      true ->
        path = Esr.Paths.users_yaml()
        doc = read_or_empty(path)

        users = Map.get(doc, "users") || %{}

        if Map.has_key?(users, name) do
          Render.error(__MODULE__.command_meta(), :already_exists, %{name: name})
        else
          uuid = UUID.uuid4()
          ws_uuid = UUID.uuid4()
          ws_name = "#{name}-default"

          updated_users = Map.put(users, name, %{"feishu_ids" => []})
          updated_doc = Map.put(doc, "users", updated_users)

          set_default_fn = Keyword.get(opts, :set_default_fn, @default_set_default_fn)

          # Spec §9 invariant 5: atomic. On any step failure, undo every
          # disk artifact written by earlier steps so a re-run of
          # /user:add <name> doesn't hit the spurious already_exists.
          result =
            with :ok <- Esr.Yaml.Writer.write(path, updated_doc),
                 :ok <- write_user_json(uuid, name, ws_uuid),
                 :ok <- sync_reload_user_registry(path),
                 :ok <- create_user_default_workspace(ws_uuid, ws_name, name),
                 :ok <- set_default_fn.(name, ws_uuid) do
              :ok
            end

          case result do
            :ok ->
              populate_name_index(name, uuid)
              auto_admin = maybe_grant_admin(uuid, name)

              {:ok,
               %{
                 "text" =>
                   "added esr user #{name}" <>
                     if(auto_admin, do: " (auto-admin: bootstrap)", else: ""),
                 "id" => uuid,
                 "default_workspace" => ws_name,
                 "default_workspace_id" => ws_uuid,
                 "auto_admin" => auto_admin
               }}

            {:error, reason} ->
              rollback_partial_add(name, uuid, ws_uuid, ws_name, doc, path)

              Render.error(__MODULE__.command_meta(), :write_failed, %{detail: inspect(reason)})
          end
        end
    end
  end

  def execute(_cmd, _opts) do
    Render.error(__MODULE__.command_meta(), :invalid_args, %{
      detail: "user_add requires args.name (non-empty string)"
    })
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp read_or_empty(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = m} -> m
      _ -> %{"users" => %{}}
    end
  end

  defp write_user_json(uuid, username, default_workspace_id) do
    dir = Path.join(Esr.Paths.users_dir(), uuid)

    with :ok <- File.mkdir_p(dir) do
      path = Path.join(dir, "user.json")
      tmp = path <> ".tmp"

      doc = %{
        "schema_version" => 1,
        "id" => uuid,
        "username" => username,
        "display_name" => "",
        "feishu_ids" => [],
        "default_workspace_id" => default_workspace_id,
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      with :ok <- File.write(tmp, Jason.encode!(doc, pretty: true)),
           :ok <- File.rename(tmp, path) do
        :ok
      end
    end
  rescue
    e -> {:error, e}
  end

  # The Watcher (FSEvents-based) reloads `User.Registry` asynchronously on
  # users.yaml change events. Inside this command we need the new user to
  # appear in `:esr_users_by_name` *before* `set_default_workspace/2` runs,
  # otherwise that call returns `{:error, :not_found}`. Calling
  # `FileLoader.load/1` synchronously here makes the with-chain atomic.
  defp sync_reload_user_registry(yaml_path) do
    case Esr.Entity.User.FileLoader.load(yaml_path) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, e}
  end

  defp create_user_default_workspace(ws_uuid, ws_name, owner) do
    dir = Esr.Paths.workspace_dir(ws_name)

    with :ok <- File.mkdir_p(dir) do
      ws = %Esr.Resource.Workspace.Struct{
        id: ws_uuid,
        name: ws_name,
        owner: owner,
        folders: [],
        agent: "cc",
        settings: %{},
        env: %{},
        chats: [],
        transient: false,
        location: {:esr_bound, dir}
      }

      Esr.Resource.Workspace.Registry.put(ws)
    end
  rescue
    e -> {:error, e}
  end

  # Best-effort cleanup. Each step is idempotent — missing artifacts are
  # silently fine. Sub-step failures are logged (we can't fail the user
  # further) but don't abort the rollback chain.
  defp rollback_partial_add(name, uuid, ws_uuid, ws_name, original_doc, yaml_path) do
    rollback_step(:revert_users_yaml, fn ->
      Esr.Yaml.Writer.write(yaml_path, original_doc)
    end)

    rollback_step(:delete_user_json_dir, fn ->
      Esr.Paths.users_dir() |> Path.join(uuid) |> File.rm_rf()
      :ok
    end)

    rollback_step(:resync_user_registry, fn ->
      sync_reload_user_registry(yaml_path)
    end)

    rollback_step(:delete_workspace_dir, fn ->
      Esr.Paths.workspace_dir(ws_name) |> File.rm_rf()
      :ok
    end)

    rollback_step(:evict_workspace_registry, fn ->
      _ = Esr.Resource.Workspace.Registry.delete_by_id(ws_uuid)
      :ok
    end)

    Logger.warning(
      "User.Add: rolled back partial create for user '#{name}' (uuid=#{uuid}, ws=#{ws_name})"
    )

    :ok
  end

  defp rollback_step(label, fun) do
    case fun.() do
      :ok ->
        :ok

      other ->
        Logger.warning(
          "User.Add rollback step #{inspect(label)} non-:ok result: #{inspect(other)}"
        )
    end
  rescue
    e ->
      Logger.warning(
        "User.Add rollback step #{inspect(label)} crashed: #{inspect(e)}"
      )
  end

  defp populate_name_index(name, uuid) do
    case NameIndex.put(:esr_user_name_index, name, uuid) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "User.Add: NameIndex.put failed for #{inspect(name)} / #{inspect(uuid)}: #{inspect(reason)}"
        )
    end
  end

  # Audit follow-up #2 / "first-user-auto-admin" (capabilities spec §9.1
  # extension, 2026-05-09): if no principal currently holds the bare `*`
  # wildcard, the runtime is in a fresh-install state — promote the user
  # we just created to admin by appending a grant entry to capabilities.yaml.
  # Subsequent `/user:add` calls find an admin and no-op.
  #
  # Returns boolean indicating whether the auto-admin grant was applied,
  # so the caller's response can surface it (`auto_admin: true`).
  #
  # Pre-2026-05-09 the only bootstrap path was `ESR_BOOTSTRAP_PRINCIPAL_ID`
  # env var (read by `Esr.Resource.Capability.Supervisor.maybe_bootstrap_file/1`
  # at boot). That stays as a complementary mechanism — env var seeds the
  # cap file before the supervisor starts; this path covers the case where
  # the supervisor started without the env var and the operator runs
  # `esr user add <name>` to set themselves up.
  defp maybe_grant_admin(uuid, name) do
    if Esr.Resource.Capability.Grants.any_admin?() do
      false
    else
      cap_path = Esr.Paths.capabilities_yaml()
      append_admin_grant(cap_path, uuid)
      sync_reload_capabilities(cap_path)
      # 2026-05-09 zero-config bootstrap (spec § 3.4): also write
      # operator.json so the CLI's submitter resolution chain can pick
      # this user up on subsequent commands without env vars.
      write_operator_json(uuid, name)
      Logger.info(
        "User.Add: auto-admin granted to #{uuid} (no prior admin in capabilities.yaml)"
      )
      true
    end
  rescue
    e ->
      Logger.warning(
        "User.Add: maybe_grant_admin/2 crashed (#{inspect(e)}); skipping auto-admin"
      )
      false
  end

  # 2026-05-09 zero-config bootstrap (spec § 3.4): persist the active
  # CLI operator pointer so `Esr.Cli.Main.resolve_submitter/0` can read
  # it without an env var. Best-effort — a write failure logs a warning
  # and returns :ok so the auto-admin path doesn't crash on a stale
  # filesystem (the user's caps still landed in capabilities.yaml).
  defp write_operator_json(uuid, name) do
    path = Esr.Paths.operator_json()

    doc = %{
      "schema_version" => 1,
      "principal_id" => uuid,
      "name" => name,
      "set_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "set_by" => "user_add"
    }

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(doc, pretty: true)) do
      :ok
    else
      err ->
        Logger.warning("User.Add: operator.json write failed: #{inspect(err)}")
        :ok
    end
  end

  defp append_admin_grant(path, uuid) do
    doc =
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = m} -> m
        _ -> %{"principals" => []}
      end

    principals = Map.get(doc, "principals") || []

    new_entry = %{
      "id" => uuid,
      "kind" => "esr_user",
      "capabilities" => ["*"],
      "note" => "auto-admin (first user_add, no prior admin in capabilities.yaml)"
    }

    updated = Map.put(doc, "principals", principals ++ [new_entry])

    :ok = File.mkdir_p(Path.dirname(path))
    Esr.Yaml.Writer.write(path, updated)
  end

  defp sync_reload_capabilities(path) do
    # Pull the new grant into the live ETS snapshot synchronously so
    # subsequent /user:add calls (or anything reading Grants in the
    # same VM) see the admin without waiting for the FSEvents Watcher.
    case Esr.Resource.Capability.FileLoader.load(path) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning(
          "User.Add: capabilities reload after auto-admin failed: #{inspect(reason)}"
        )
        :ok
    end
  end
end

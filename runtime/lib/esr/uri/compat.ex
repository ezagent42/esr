defmodule Esr.Uri.Compat do
  @moduledoc """
  MIGRATION SHIM (2026-05-12 → DELETED in PR-5).

  Return-shape-preserving wrappers for old User.Registry / User.NameIndex /
  Workspace.Registry / Workspace.NameIndex APIs. Internally call Esr.Uri.*.

  Lets PR-1 / PR-2 do mechanical sed-replacement instead of touching every
  caller's logic.

  Each wrapper exposes BOTH a /1 form (preferred new style) and the legacy
  /2 form (which absorbs the ETS-table atom that the old NameIndex APIs
  took as first arg). This lets sed-rename catch every caller, regardless
  of which arity they were using.

  Spec: docs/superpowers/specs/2026-05-12-uri-identity-design.md §10
  Plan: docs/superpowers/plans/2026-05-12-uri-identity-plan.md PR-0 Task 0.4
  """

  # ────────────────────────────────────────────────────────────
  # User wrappers
  # ────────────────────────────────────────────────────────────

  @doc """
  Replaces Esr.Entity.User.NameIndex.id_for_name/1 and /2.
  Return shape: `{:ok, uuid}` or `:not_found`.
  """
  @spec uuid_for_user_name(String.t()) :: {:ok, String.t()} | :not_found
  def uuid_for_user_name(name) when is_binary(name) do
    case Esr.Uri.resolve("esr://localhost/users/by-name/" <> name) do
      {:ok, "esr://localhost/users/" <> uuid} -> {:ok, uuid}
      _ -> :not_found
    end
  end

  @spec uuid_for_user_name(atom(), String.t()) :: {:ok, String.t()} | :not_found
  def uuid_for_user_name(_table, name), do: uuid_for_user_name(name)

  @doc """
  Replaces Esr.Entity.User.NameIndex.name_for_id/1 and /2.
  Return shape: `{:ok, name}` or `:not_found`.
  """
  @spec name_for_user_uuid(String.t()) :: {:ok, String.t()} | :not_found
  def name_for_user_uuid(uuid) when is_binary(uuid) do
    case Esr.Uri.get_entity("esr://localhost/users/" <> uuid) do
      {:ok, :user, %{username: name}} -> {:ok, name}
      _ -> :not_found
    end
  end

  @spec name_for_user_uuid(atom(), String.t()) :: {:ok, String.t()} | :not_found
  def name_for_user_uuid(_table, uuid), do: name_for_user_uuid(uuid)

  @doc """
  Replaces Esr.Entity.User.Registry.lookup_by_feishu_id/1.
  Returns the bound username (NOT the UUID).
  """
  @spec username_for_feishu_id(String.t()) :: {:ok, String.t()} | :not_found
  def username_for_feishu_id(ou_id) when is_binary(ou_id) do
    case Esr.Uri.resolve("esr://localhost/users/feishu/" <> ou_id) do
      {:ok, "esr://localhost/users/" <> uuid} -> name_for_user_uuid(uuid)
      _ -> :not_found
    end
  end

  @doc "Replaces Esr.Entity.User.Registry.get_by_id/1."
  @spec user_by_uuid(String.t()) :: {:ok, struct()} | :not_found
  def user_by_uuid(uuid) when is_binary(uuid) do
    case Esr.Uri.get_entity("esr://localhost/users/" <> uuid) do
      {:ok, :user, data} -> {:ok, data}
      _ -> :not_found
    end
  end

  @doc "Replaces Esr.Entity.User.Registry.get/1 (by username)."
  @spec user_by_name(String.t()) :: {:ok, struct()} | :not_found
  def user_by_name(name) when is_binary(name) do
    case Esr.Uri.get_entity("esr://localhost/users/by-name/" <> name) do
      {:ok, :user, data} -> {:ok, data}
      _ -> :not_found
    end
  end

  @doc """
  Replaces Esr.Entity.User.Registry.get_default_workspace/1 (takes username).
  Returns the workspace UUID via the user's User struct.
  """
  @spec default_workspace_for_user_name(String.t()) :: {:ok, String.t()} | :not_found
  def default_workspace_for_user_name(name) when is_binary(name) do
    case user_by_name(name) do
      {:ok, %{default_workspace_id: id}} when is_binary(id) and id != "" ->
        {:ok, id}
      _ ->
        :not_found
    end
  end

  @doc """
  Replaces Esr.Entity.User.Registry.list/0. Returns every User struct
  stored in the URI store entity rows (kind: :user), unsorted.
  """
  @spec list_users() :: [struct()]
  def list_users do
    :esr_uri_store
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {_uri, {:entity, :user, data}} -> [data]
      _ -> []
    end)
  rescue
    ArgumentError -> []
  end

  @doc """
  Replaces Esr.Entity.User.Registry.list_all/0. Returns `[{uuid, %User{}}]`.
  """
  @spec list_users_with_uuid() :: [{String.t(), struct()}]
  def list_users_with_uuid do
    :esr_uri_store
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {"esr://localhost/users/" <> uuid, {:entity, :user, data}} ->
        if String.contains?(uuid, "/") do
          []
        else
          [{uuid, data}]
        end

      _ ->
        []
    end)
  rescue
    ArgumentError -> []
  end

  @doc """
  Replaces Esr.Entity.User.Registry.set_default_workspace/2.

  Updates the User struct in the URI store entity row. Disk durability is
  the caller's responsibility (it normally writes `user.json` + invokes
  FileLoader); this only updates the in-memory store so subsequent reads
  see the new value within the same boot.
  """
  @spec set_default_workspace_for_user_name(String.t(), String.t()) ::
          :ok | {:error, :not_found}
  def set_default_workspace_for_user_name(name, ws_id)
      when is_binary(name) and is_binary(ws_id) do
    with {:ok, uuid} <- uuid_for_user_name(name),
         {:ok, user} <- user_by_uuid(uuid) do
      updated = %{user | default_workspace_id: ws_id}
      Esr.Uri.put_entity("esr://localhost/users/" <> uuid, :user, updated)
    else
      _ -> {:error, :not_found}
    end
  end

  # ────────────────────────────────────────────────────────────
  # Workspace wrappers
  # ────────────────────────────────────────────────────────────

  @doc "Replaces Esr.Resource.Workspace.NameIndex.id_for_name/1 and /2."
  @spec uuid_for_workspace_name(String.t()) :: {:ok, String.t()} | :not_found
  def uuid_for_workspace_name(name) when is_binary(name) do
    case Esr.Uri.resolve("esr://localhost/workspaces/by-name/" <> name) do
      {:ok, "esr://localhost/workspaces/" <> uuid} -> {:ok, uuid}
      _ -> :not_found
    end
  end

  @spec uuid_for_workspace_name(atom(), String.t()) :: {:ok, String.t()} | :not_found
  def uuid_for_workspace_name(_table, name), do: uuid_for_workspace_name(name)

  @doc "Replaces Esr.Resource.Workspace.NameIndex.name_for_id/1 and /2."
  @spec name_for_workspace_uuid(String.t()) :: {:ok, String.t()} | :not_found
  def name_for_workspace_uuid(uuid) when is_binary(uuid) do
    case Esr.Uri.get_entity("esr://localhost/workspaces/" <> uuid) do
      {:ok, :workspace, %{name: name}} -> {:ok, name}
      _ -> :not_found
    end
  end

  @spec name_for_workspace_uuid(atom(), String.t()) :: {:ok, String.t()} | :not_found
  def name_for_workspace_uuid(_table, uuid), do: name_for_workspace_uuid(uuid)

  @doc "Replaces Esr.Resource.Workspace.Registry.get_by_id/1."
  @spec workspace_by_uuid(String.t()) :: {:ok, struct()} | :not_found
  def workspace_by_uuid(uuid) when is_binary(uuid) do
    case Esr.Uri.get_entity("esr://localhost/workspaces/" <> uuid) do
      {:ok, :workspace, data} -> {:ok, data}
      _ -> :not_found
    end
  end

  @doc "Replaces Esr.Resource.Workspace.Registry.workspace_for_chat/2 (returns name)."
  @spec workspace_name_for_chat(String.t(), String.t()) :: {:ok, String.t()} | :not_found
  def workspace_name_for_chat(chat_id, app_id)
      when is_binary(chat_id) and is_binary(app_id) do
    case Esr.Uri.resolve("esr://localhost/workspaces/by-chat/#{chat_id}/#{app_id}") do
      {:ok, "esr://localhost/workspaces/" <> uuid} -> name_for_workspace_uuid(uuid)
      _ -> :not_found
    end
  end

  @doc """
  Replaces Esr.Resource.Workspace.Registry.list_all/0. Returns every
  Workspace struct stored in the URI store, sorted by name.
  """
  @spec list_workspaces() :: [struct()]
  def list_workspaces do
    :esr_uri_store
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {_uri, {:entity, :workspace, data}} -> [data]
      _ -> []
    end)
    |> Enum.sort_by(& &1.name)
  rescue
    ArgumentError -> []
  end

  @doc """
  Replaces Esr.Resource.Workspace.Registry.list_names/0. Returns
  `{:ok, [name]}` of workspace names sorted alphabetically.
  """
  @spec list_workspace_names() :: {:ok, [String.t()]}
  def list_workspace_names do
    names =
      list_workspaces()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    {:ok, names}
  end

  @doc """
  Replaces Esr.Resource.Workspace.Registry.put/1 (upsert semantics).

  Writes:
    - canonical entity row: esr://localhost/workspaces/<uuid>
    - by-name alias:        esr://localhost/workspaces/by-name/<name>
    - per-chat aliases:     esr://localhost/workspaces/by-chat/<cid>/<aid>
    - disk: workspace.json (location-dependent)

  Upsert: if a workspace with the same `name` already exists under a
  DIFFERENT uuid, the prior canonical+aliases are removed first.
  """
  @spec workspace_put(struct()) :: :ok | {:error, term()}
  def workspace_put(%Esr.Resource.Workspace.Struct{} = ws) do
    # If a workspace with this name exists under a different uuid, clear it.
    case uuid_for_workspace_name(ws.name) do
      {:ok, old_id} when old_id != ws.id ->
        _ = workspace_delete_by_id(old_id)

      _ ->
        :ok
    end

    # If the SAME uuid was previously stored under a DIFFERENT name, clear
    # the stale by-name alias so the new name resolves cleanly.
    case name_for_workspace_uuid(ws.id) do
      {:ok, old_name} when old_name != ws.name ->
        Esr.Uri.delete("esr://localhost/workspaces/by-name/" <> old_name)

      _ ->
        :ok
    end

    canonical = "esr://localhost/workspaces/" <> ws.id

    # Remove every existing by-chat alias for this canonical so chats
    # dropped from the struct (e.g. /workspace:unbind-chat) actually
    # vanish from the URI store. The current ws.chats list is then
    # re-added below.
    drop_by_chat_aliases(canonical)

    :ok = Esr.Uri.put_entity(canonical, :workspace, ws)
    _ = Esr.Uri.alias(canonical, "esr://localhost/workspaces/by-name/" <> ws.name)

    Enum.each(ws.chats || [], fn chat ->
      cid = Map.get(chat, :chat_id) || Map.get(chat, "chat_id")
      aid = Map.get(chat, :app_id) || Map.get(chat, "app_id")

      if is_binary(cid) and is_binary(aid) do
        _ = Esr.Uri.alias(canonical, "esr://localhost/workspaces/by-chat/#{cid}/#{aid}")
      end
    end)

    write_workspace_to_disk(ws)
  end

  defp drop_by_chat_aliases(canonical) do
    try do
      :esr_uri_store
      |> :ets.tab2list()
      |> Enum.each(fn
        {"esr://localhost/workspaces/by-chat/" <> _ = uri, {:alias, ^canonical}} ->
          Esr.Uri.delete(uri)

        _ ->
          :ok
      end)
    rescue
      ArgumentError -> :ok
    end
  end

  defp write_workspace_to_disk(%Esr.Resource.Workspace.Struct{location: {:esr_bound, dir}} = ws) do
    Esr.Resource.Workspace.JsonWriter.write(Path.join(dir, "workspace.json"), ws)
  end

  defp write_workspace_to_disk(%Esr.Resource.Workspace.Struct{location: {:repo_bound, repo}} = ws) do
    Esr.Resource.Workspace.JsonWriter.write(Esr.Paths.workspace_json_repo(repo), ws)
  end

  defp write_workspace_to_disk(_), do: :ok

  @doc """
  Replaces Esr.Resource.Workspace.Registry.delete_by_id/1.

  Removes the canonical entity row and every alias that points at it
  (by-name, by-chat/...). Does NOT delete on-disk files — callers that
  need disk cleanup (e.g. transient workspace removal) handle that
  separately. Idempotent — returns :ok whether or not the workspace
  exists.
  """
  @spec workspace_delete_by_id(String.t()) :: :ok
  def workspace_delete_by_id(uuid) when is_binary(uuid) do
    canonical = "esr://localhost/workspaces/" <> uuid

    # Collect every alias whose target equals `canonical` and delete them.
    try do
      :esr_uri_store
      |> :ets.tab2list()
      |> Enum.each(fn
        {uri, {:alias, ^canonical}} -> Esr.Uri.delete(uri)
        _ -> :ok
      end)
    rescue
      ArgumentError -> :ok
    end

    Esr.Uri.delete(canonical)
    :ok
  end

  @doc """
  Replaces Esr.Resource.Workspace.Registry.rename/2.

  Renames the workspace `old_name` → `new_name`:
    - Updates the in-memory %Struct{} (name + ESR-bound directory path).
    - Renames the on-disk directory for ESR-bound workspaces.
    - Rewrites workspace.json with the new name.
    - Repoints the by-name alias.
  """
  @spec workspace_rename(String.t(), String.t()) :: :ok | {:error, term()}
  def workspace_rename(old_name, new_name)
      when is_binary(old_name) and is_binary(new_name) do
    with {:ok, uuid} <- uuid_for_workspace_name(old_name),
         {:ok, ws} <- workspace_by_uuid(uuid),
         :ok <- check_new_name_free(new_name) do
      new_ws =
        case ws.location do
          {:esr_bound, old_dir} ->
            new_dir = Path.join(Path.dirname(old_dir), new_name)
            :ok = File.rename(old_dir, new_dir)
            %{ws | name: new_name, location: {:esr_bound, new_dir}}

          {:repo_bound, _} ->
            %{ws | name: new_name}

          _ ->
            %{ws | name: new_name}
        end

      workspace_put(new_ws)
    end
  end

  defp check_new_name_free(name) do
    case uuid_for_workspace_name(name) do
      :not_found -> :ok
      {:ok, _} -> {:error, :name_exists}
    end
  end

  # ────────────────────────────────────────────────────────────
  # Session wrappers (PR-3)
  # ────────────────────────────────────────────────────────────

  @doc """
  Replaces Esr.Resource.Session.Registry.get_by_id/1.

  Returns `{:ok, %Session.Struct{}}` or `:not_found`.
  """
  @spec session_by_uuid(String.t()) :: {:ok, struct()} | :not_found
  def session_by_uuid(uuid) when is_binary(uuid) do
    case Esr.Uri.get_entity("esr://localhost/sessions/" <> uuid) do
      {:ok, :session, data} -> {:ok, data}
      _ -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc """
  Replaces Esr.Resource.Session.Registry.list_all/0.

  Returns every Session struct stored in the URI store entity rows
  (kind: :session), unsorted.
  """
  @spec list_sessions() :: [struct()]
  def list_sessions do
    :esr_uri_store
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {_uri, {:entity, :session, data}} -> [data]
      _ -> []
    end)
  rescue
    ArgumentError -> []
  end

  @doc """
  Replaces Esr.Session.NameIndex.Registry.lookup_by_name/4.

  Returns `{:ok, session_uuid}` for the session URI tuple
  `(env, username, workspace, name)`, or `:not_found`.
  """
  @spec session_uuid_in_scope(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | :not_found
  def session_uuid_in_scope(env, username, workspace, name)
      when is_binary(env) and is_binary(username) and is_binary(workspace) and is_binary(name) do
    uri = "esr://localhost/sessions/by-name/#{env}/#{username}/#{workspace}/#{name}"

    case Esr.Uri.resolve(uri) do
      {:ok, "esr://localhost/sessions/" <> uuid} -> {:ok, uuid}
      _ -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc """
  Replaces Esr.Session.NameIndex.Registry.list_uris/3.

  Returns `[{name, session_uuid}]` for every session URI claimed under
  the `(env, username, workspace)` prefix in the URI store.
  """
  @spec list_session_uris_in_scope(String.t(), String.t(), String.t()) ::
          [{String.t(), String.t()}]
  def list_session_uris_in_scope(env, username, workspace)
      when is_binary(env) and is_binary(username) and is_binary(workspace) do
    prefix = "esr://localhost/sessions/by-name/#{env}/#{username}/#{workspace}/"
    prefix_len = byte_size(prefix)

    :esr_uri_store
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {uri, {:alias, "esr://localhost/sessions/" <> sid}} ->
        if is_binary(uri) and byte_size(uri) > prefix_len and
             :binary.part(uri, 0, prefix_len) == prefix do
          name = :binary.part(uri, prefix_len, byte_size(uri) - prefix_len)

          # Skip worktree-branch aliases (encoded with a "by-worktree/"
          # nested key — see claim_session_uri/2 below).
          if String.starts_with?(name, "by-worktree/") do
            []
          else
            [{name, sid}]
          end
        else
          []
        end

      _ ->
        []
    end)
  rescue
    ArgumentError -> []
  end

  @doc """
  Replaces Esr.Session.NameIndex.Registry.claim_uri/2.

  Atomically claims both the `name` and the `worktree_branch` aliases
  under `(env, username, workspace, …)` against the freshly-spawned
  session UUID. Rejects with `{:error, {:name_taken, sid}}` or
  `{:error, {:worktree_taken, sid}}` on collision.

  The canonical entity row for the session must already exist in the
  URI store (callers `persist_session_record/4` does this via
  `Esr.Resource.Session.Registry.create_session/2`'s post-PR-3
  replacement, which writes the entity row before claiming the
  scope alias).
  """
  @spec claim_session_uri(
          String.t(),
          %{
            required(:env) => String.t(),
            required(:username) => String.t(),
            required(:workspace) => String.t(),
            required(:name) => String.t(),
            optional(:worktree_branch) => String.t()
          }
        ) :: :ok | {:error, term()}
  def claim_session_uri(session_uuid, %{env: env, username: u, workspace: w, name: n} = uri_components)
      when is_binary(session_uuid) and is_binary(env) and is_binary(u) and is_binary(w) and
             is_binary(n) do
    canonical = "esr://localhost/sessions/" <> session_uuid
    name_alias = "esr://localhost/sessions/by-name/#{env}/#{u}/#{w}/#{n}"

    worktree_alias =
      case Map.get(uri_components, :worktree_branch) do
        wb when is_binary(wb) and wb != "" ->
          "esr://localhost/sessions/by-name/#{env}/#{u}/#{w}/by-worktree/#{wb}"

        _ ->
          nil
      end

    # Pre-check for collisions so we can return semantic error tuples
    # like the legacy NameIndex.Registry.claim_uri did.
    name_owner = resolve_session_alias(name_alias)
    wt_owner = if worktree_alias, do: resolve_session_alias(worktree_alias), else: :not_found

    cond do
      match?({:ok, _}, name_owner) and name_owner != {:ok, session_uuid} ->
        {:ok, taken_by} = name_owner
        {:error, {:name_taken, taken_by}}

      match?({:ok, _}, wt_owner) and wt_owner != {:ok, session_uuid} ->
        {:ok, taken_by} = wt_owner
        {:error, {:worktree_taken, taken_by}}

      true ->
        # Ensure canonical entity row exists (idempotent — if it's
        # already a full Session struct, this is a no-op via the
        # claim path's perspective). If not, create a placeholder
        # struct so put_alias's "canonical must be entity" invariant
        # holds.
        ensure_session_canonical(canonical, session_uuid)

        # Write aliases (idempotent on re-claim of same sid).
        _ = put_or_ignore_alias(name_alias, canonical)
        if worktree_alias, do: put_or_ignore_alias(worktree_alias, canonical)
        :ok
    end
  end

  def claim_session_uri(_sid, _bad),
    do: {:error, {:invalid_args, "claim_session_uri requires env/username/workspace/name"}}

  defp resolve_session_alias(uri) do
    case Esr.Uri.resolve(uri) do
      {:ok, "esr://localhost/sessions/" <> sid} -> {:ok, sid}
      _ -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  defp ensure_session_canonical(canonical, session_uuid) do
    case Esr.Uri.Store.lookup_raw(canonical) do
      {:ok, {:entity, :session, _}} ->
        :ok

      _ ->
        Esr.Uri.put_entity(canonical, :session, %Esr.Resource.Session.Struct{id: session_uuid})
    end
  rescue
    ArgumentError -> :ok
  end

  defp put_or_ignore_alias(alias_uri, canonical) do
    case Esr.Uri.alias(canonical, alias_uri) do
      :ok -> :ok
      {:error, :alias_exists} -> :ok
      other -> other
    end
  end

  @doc """
  Replaces Esr.Session.NameIndex.Registry.release_uri/1.

  Drops every alias whose target is the session's canonical URI.
  Idempotent — returns :ok whether or not any alias exists.
  """
  @spec release_session_uri(String.t()) :: :ok
  def release_session_uri(session_uuid) when is_binary(session_uuid) do
    canonical = "esr://localhost/sessions/" <> session_uuid

    try do
      :esr_uri_store
      |> :ets.tab2list()
      |> Enum.each(fn
        {alias_uri, {:alias, ^canonical}} -> Esr.Uri.delete(alias_uri)
        _ -> :ok
      end)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @doc """
  Replaces Esr.Resource.Session.Registry.create_session/2.

  Writes `<data_dir>/sessions/<sid>/session.json` AND inserts a
  canonical `:session` entity row into the URI store. Returns
  `{:ok, sid}` mirroring the legacy contract.
  """
  @spec create_session(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def create_session(data_dir, attrs) when is_binary(data_dir) and is_map(attrs) do
    uuid =
      Map.get(attrs, :session_id) || Map.get(attrs, "session_id") ||
        Esr.Resource.Session.Id.new()

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    session = %Esr.Resource.Session.Struct{
      id: uuid,
      name: Map.get(attrs, :name) || Map.get(attrs, "name", ""),
      owner_user: Map.get(attrs, :owner_user) || Map.get(attrs, "owner_user", ""),
      workspace_id: Map.get(attrs, :workspace_id) || Map.get(attrs, "workspace_id", ""),
      agent_ids: [],
      primary_agent: nil,
      attached_chats: [],
      created_at: now,
      transient: Map.get(attrs, :transient, false)
    }

    session_dir = Path.join([data_dir, "sessions", uuid])
    File.mkdir_p!(session_dir)
    session_json_path = Path.join(session_dir, "session.json")

    case Esr.Resource.Session.JsonWriter.write(session_json_path, session) do
      :ok ->
        # In-memory: write the canonical :session entity row so the
        # rest of the URI-store-backed lookups (session_by_uuid/1,
        # list_sessions/0, capability translator) see it.
        if Process.whereis(Esr.Uri.Store) do
          _ = Esr.Uri.put_entity("esr://localhost/sessions/" <> uuid, :session, session)
        end

        {:ok, uuid}

      {:error, reason} ->
        {:error, {:write_failed, reason}}
    end
  end

  @doc """
  Replaces Esr.Resource.Session.Registry.add_agent_to_session/5.

  Delegates the in-memory write to Esr.Entity.Agent.InstanceRegistry
  + persists per-instance JSON + updates session.json's agent_ids,
  then refreshes the canonical :session entity row in the URI store.
  """
  @spec add_agent_to_session(String.t(), String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def add_agent_to_session(data_dir, session_id, type, name, config)
      when is_binary(data_dir) and is_binary(session_id) and is_binary(type) and
             is_binary(name) and is_map(config) do
    case Esr.Entity.Agent.InstanceRegistry.add_instance(%{
           session_id: session_id,
           type: type,
           name: name,
           config: config
         }) do
      :ok -> persist_session_agents(data_dir, session_id)
      {:error, _} = err -> err
    end
  end

  @doc """
  Replaces Esr.Resource.Session.Registry.remove_agent_from_session/3.
  """
  @spec remove_agent_from_session(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def remove_agent_from_session(session_id, name, data_dir)
      when is_binary(session_id) and is_binary(name) and is_binary(data_dir) do
    case Esr.Entity.Agent.InstanceRegistry.remove_instance(session_id, name) do
      :ok -> persist_session_agents(data_dir, session_id)
      {:error, _} = err -> err
    end
  end

  # Shared post-mutator: rewrite per-instance JSON + agent_ids in
  # session.json + URI store canonical entity row. Mirrors what the
  # deleted Registry's persist_agents/2 did.
  defp persist_session_agents(data_dir, session_id) do
    alias Esr.Entity.Agent.InstanceJson

    instances = Esr.Entity.Agent.InstanceRegistry.list(session_id)

    primary =
      case Esr.Entity.Agent.InstanceRegistry.primary(session_id) do
        {:ok, n} -> n
        :not_found -> nil
      end

    Enum.each(instances, fn inst ->
      canonical_sid = List.first(inst.session_ids) || session_id
      path = Path.join([data_dir, "sessions", canonical_sid, "agents", inst.id <> ".json"])
      _ = InstanceJson.write(path, inst)
    end)

    agent_ids = Enum.map(instances, & &1.id)
    session_json_path = Path.join([data_dir, "sessions", session_id, "session.json"])

    case File.read(session_json_path) do
      {:ok, raw} ->
        doc =
          raw
          |> Jason.decode!()
          |> Map.put("agent_ids", agent_ids)
          |> Map.put("primary_agent", primary)
          |> Map.delete("agents")

        tmp_path = session_json_path <> ".tmp"
        File.write!(tmp_path, Jason.encode!(doc, pretty: true))
        File.rename!(tmp_path, session_json_path)

        # Also refresh the URI store canonical entity row.
        case session_by_uuid(session_id) do
          {:ok, s} ->
            updated = %{s | agent_ids: agent_ids, primary_agent: primary}

            if Process.whereis(Esr.Uri.Store) do
              _ =
                Esr.Uri.put_entity(
                  "esr://localhost/sessions/" <> session_id,
                  :session,
                  updated
                )
            end

            :ok

          :not_found ->
            :ok
        end

      {:error, reason} ->
        {:error, {:session_json_missing, reason}}
    end
  end

  # ────────────────────────────────────────────────────────────
  # Agent wrappers (PR-4)
  # ────────────────────────────────────────────────────────────
  #
  # The Agent domain still uses `Esr.Entity.Agent.InstanceRegistry` as
  # its backing GenServer + ETS store. PR-4 (2026-05-12) migrates every
  # external caller to these wrappers, which:
  #
  #   * Read through the URI store first when possible
  #     (`agent_in_session/2`, `agent_by_uuid/1`) using the canonical
  #     `esr://localhost/agents/<uuid>` row + `agents/by-name/<sid>/<name>`
  #     alias. The wrappers fall back to the InstanceRegistry ETS read so
  #     legacy state populated before URI mirroring is reachable.
  #   * Mirror every mutation to the URI store so URI-store-first reads
  #     stay consistent with InstanceRegistry's authoritative state.
  #   * Implement the documented BREAKING change on `primary/2`: the new
  #     `primary_agent_uuid/1` returns `{:ok, agent_uuid}` (the
  #     `%Instance{}.id`) instead of `{:ok, name}`. Display callers must
  #     chain `agent_by_uuid/1` to recover the name.
  #
  # PR-5 will delete `Esr.Entity.Agent.InstanceRegistry` after the URI-
  # store rows + a thin pid registry replace its remaining responsibilities.

  @doc """
  Replaces `Esr.Entity.Agent.InstanceRegistry.get/3`
  (by session_id + name). URI-store-first; falls back to InstanceRegistry
  for rows that haven't been mirrored yet.
  """
  @spec agent_in_session(String.t(), String.t()) :: {:ok, struct()} | :not_found
  def agent_in_session(session_id, name)
      when is_binary(session_id) and is_binary(name) do
    case Esr.Uri.get_entity("esr://localhost/agents/by-name/#{session_id}/#{name}") do
      {:ok, :agent, data} ->
        {:ok, data}

      _ ->
        # Fallback: InstanceRegistry still owns rows that haven't been
        # mirrored to the URI store. Mirror on read so subsequent reads
        # skip the GenServer call.
        case Esr.Entity.Agent.InstanceRegistry.get(session_id, name) do
          {:ok, inst} ->
            _ = mirror_instance_to_uri_store(inst)
            {:ok, inst}

          :not_found ->
            :not_found
        end
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc """
  Replaces `Esr.Entity.Agent.InstanceRegistry.get_by_uuid/1`
  (by instance_id). URI-store-first.
  """
  @spec agent_by_uuid(String.t()) :: {:ok, struct()} | :not_found
  def agent_by_uuid(uuid) when is_binary(uuid) do
    case Esr.Uri.get_entity("esr://localhost/agents/" <> uuid) do
      {:ok, :agent, data} -> {:ok, data}
      _ -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc """
  Replaces `Esr.Entity.Agent.InstanceRegistry.primary/2`.

  **BREAKING (PR-4, 2026-05-12)**: returns the agent UUID
  (`%Instance{}.id`), NOT the name. Callers that need the display name
  must chain `agent_by_uuid/1` and read `.name`.
  """
  @spec primary_agent_uuid(String.t()) :: {:ok, String.t()} | :not_found
  def primary_agent_uuid(session_id) when is_binary(session_id) do
    case Esr.Uri.resolve("esr://localhost/agents/by-primary-for/" <> session_id) do
      {:ok, "esr://localhost/agents/" <> uuid} ->
        {:ok, uuid}

      _ ->
        # Fallback to InstanceRegistry — translate name → uuid by
        # consulting the instance row, then mirror to the URI store.
        case Esr.Entity.Agent.InstanceRegistry.primary(session_id) do
          {:ok, name} ->
            case Esr.Entity.Agent.InstanceRegistry.get(session_id, name) do
              {:ok, inst} ->
                _ = mirror_instance_to_uri_store(inst)
                _ = mirror_primary_alias(session_id, inst.id)
                {:ok, inst.id}

              :not_found ->
                :not_found
            end

          :not_found ->
            :not_found
        end
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc """
  Replaces `Esr.Entity.Agent.InstanceRegistry.list/2`
  (list agents in session).
  """
  @spec list_agents_in_session(String.t()) :: [struct()]
  def list_agents_in_session(session_id) when is_binary(session_id) do
    # InstanceRegistry is still the authoritative source for the
    # per-session list (it tracks `session_ids` arrays). Mirror each
    # entry to the URI store on read so subsequent point-lookups skip
    # the GenServer.
    instances = Esr.Entity.Agent.InstanceRegistry.list(session_id)
    Enum.each(instances, &mirror_instance_to_uri_store/1)
    instances
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  Replaces `Esr.Entity.Agent.InstanceRegistry.names_for_session/2`.
  """
  @spec agent_names_in_session(String.t()) :: [String.t()]
  def agent_names_in_session(session_id) when is_binary(session_id) do
    list_agents_in_session(session_id) |> Enum.map(& &1.name)
  end

  @doc """
  Replaces `Esr.Entity.Agent.InstanceRegistry.pty_actor_id_for/3`.
  """
  @spec pty_actor_id_for(String.t(), String.t()) :: {:ok, String.t()} | :not_found
  def pty_actor_id_for(session_id, name)
      when is_binary(session_id) and is_binary(name) do
    case agent_in_session(session_id, name) do
      {:ok, %{actor_ids: %{pty: pty_id}}} when is_binary(pty_id) -> {:ok, pty_id}
      _ -> :not_found
    end
  end

  @doc """
  Replaces `Esr.Entity.Agent.InstanceRegistry.add_instance/2`.

  Delegates to the InstanceRegistry GenServer (authoritative state)
  then mirrors the resulting `%Instance{}` rows into the URI store.
  """
  @spec add_instance(map()) :: :ok | {:error, {:duplicate_agent_name, String.t()}}
  def add_instance(attrs) when is_map(attrs) do
    case Esr.Entity.Agent.InstanceRegistry.add_instance(attrs) do
      :ok ->
        _ = mirror_session_to_uri_store(extract_session_id(attrs))
        :ok

      err ->
        err
    end
  end

  @doc """
  Replaces `Esr.Entity.Agent.InstanceRegistry.add_instance_and_spawn/2`.
  """
  @spec add_instance_and_spawn(map()) ::
          {:ok, %{cc_pid: pid(), pty_pid: pid(), actor_ids: map()}}
          | {:error, term()}
  def add_instance_and_spawn(attrs) when is_map(attrs) do
    case Esr.Entity.Agent.InstanceRegistry.add_instance_and_spawn(attrs) do
      {:ok, _result} = ok ->
        _ = mirror_session_to_uri_store(extract_session_id(attrs))
        ok

      err ->
        err
    end
  end

  @doc """
  Replaces `Esr.Entity.Agent.InstanceRegistry.attach_to_session/4`.
  """
  @spec attach_to_session(String.t(), String.t(), String.t()) ::
          :ok | {:error, :not_found | {:name_taken_in_target, String.t()}}
  def attach_to_session(name, source_sid, target_sid)
      when is_binary(name) and is_binary(source_sid) and is_binary(target_sid) do
    case Esr.Entity.Agent.InstanceRegistry.attach_to_session(name, source_sid, target_sid) do
      :ok ->
        _ = mirror_session_to_uri_store(source_sid)
        _ = mirror_session_to_uri_store(target_sid)
        :ok

      err ->
        err
    end
  end

  @doc """
  Replaces `Esr.Entity.Agent.InstanceRegistry.remove_instance/3`.
  """
  @spec remove_instance(String.t(), String.t()) ::
          :ok | {:error, :cannot_remove_primary | :not_found}
  def remove_instance(session_id, name)
      when is_binary(session_id) and is_binary(name) do
    case Esr.Entity.Agent.InstanceRegistry.remove_instance(session_id, name) do
      :ok ->
        # Drop the by-name alias for this (session_id, name) pair. The
        # canonical entity row may still be valid (instance attached to
        # other sessions); list_agents_in_session/1 below will re-mirror.
        _ = Esr.Uri.delete("esr://localhost/agents/by-name/#{session_id}/#{name}")
        _ = mirror_session_to_uri_store(session_id)
        :ok

      err ->
        err
    end
  end

  @doc """
  Replaces `Esr.Entity.Agent.InstanceRegistry.set_primary/3`.
  """
  @spec set_primary(String.t(), String.t()) :: :ok | {:error, :not_found}
  def set_primary(session_id, name)
      when is_binary(session_id) and is_binary(name) do
    case Esr.Entity.Agent.InstanceRegistry.set_primary(session_id, name) do
      :ok ->
        case Esr.Entity.Agent.InstanceRegistry.get(session_id, name) do
          {:ok, inst} ->
            _ = mirror_instance_to_uri_store(inst)
            _ = mirror_primary_alias(session_id, inst.id)
            :ok

          :not_found ->
            :ok
        end

      err ->
        err
    end
  end

  @doc """
  Replaces `Esr.Entity.Agent.InstanceRegistry.rename_instance/4`.
  """
  @spec rename_instance(String.t(), String.t(), String.t()) ::
          :ok | {:error, :not_found | :duplicate_agent_name}
  def rename_instance(session_id, name, new_name)
      when is_binary(session_id) and is_binary(name) and is_binary(new_name) do
    case Esr.Entity.Agent.InstanceRegistry.rename_instance(session_id, name, new_name) do
      :ok ->
        # Drop the old by-name alias on every session the instance is
        # attached to (rename is global across `session_ids`); the new
        # name's aliases are populated by mirror_session_to_uri_store/1
        # via the InstanceRegistry's authoritative session_ids list.
        case Esr.Entity.Agent.InstanceRegistry.get(session_id, new_name) do
          {:ok, inst} ->
            Enum.each(inst.session_ids, fn s ->
              _ = Esr.Uri.delete("esr://localhost/agents/by-name/#{s}/#{name}")
              _ = mirror_session_to_uri_store(s)
            end)

            :ok

          :not_found ->
            :ok
        end

      err ->
        err
    end
  end

  # ── private mirror helpers ──

  # Write the %Instance{} record at the canonical agent URI + the
  # per-session by-name aliases. Idempotent.
  defp mirror_instance_to_uri_store(%Esr.Entity.Agent.Instance{} = inst) do
    if Process.whereis(Esr.Uri.Store) && is_binary(inst.id) do
      canonical = "esr://localhost/agents/" <> inst.id
      _ = Esr.Uri.put_entity(canonical, :agent, inst)

      Enum.each(inst.session_ids || [], fn sid ->
        if is_binary(sid) and is_binary(inst.name) do
          _ = put_or_ignore_agent_alias(canonical, "esr://localhost/agents/by-name/#{sid}/#{inst.name}")
        end
      end)

      :ok
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp mirror_instance_to_uri_store(_), do: :ok

  defp mirror_primary_alias(session_id, agent_uuid)
       when is_binary(session_id) and is_binary(agent_uuid) do
    if Process.whereis(Esr.Uri.Store) do
      canonical = "esr://localhost/agents/" <> agent_uuid
      alias_uri = "esr://localhost/agents/by-primary-for/" <> session_id

      # by-primary is a 1-of-N alias — drop any prior alias before
      # re-pointing it at the new canonical.
      _ = Esr.Uri.delete(alias_uri)
      _ = put_or_ignore_agent_alias(canonical, alias_uri)
      :ok
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp mirror_primary_alias(_, _), do: :ok

  # Re-mirror every instance attached to `session_id` + refresh the
  # primary alias to the new primary's UUID (the InstanceRegistry's
  # `:primary` ETS row holds the name; resolve to UUID via the
  # instance lookup).
  defp mirror_session_to_uri_store(session_id) when is_binary(session_id) do
    if Process.whereis(Esr.Uri.Store) do
      instances = Esr.Entity.Agent.InstanceRegistry.list(session_id)
      Enum.each(instances, &mirror_instance_to_uri_store/1)

      case Esr.Entity.Agent.InstanceRegistry.primary(session_id) do
        {:ok, primary_name} ->
          case Esr.Entity.Agent.InstanceRegistry.get(session_id, primary_name) do
            {:ok, inst} -> mirror_primary_alias(session_id, inst.id)
            :not_found -> :ok
          end

        :not_found ->
          _ = Esr.Uri.delete("esr://localhost/agents/by-primary-for/" <> session_id)
          :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp mirror_session_to_uri_store(_), do: :ok

  defp put_or_ignore_agent_alias(canonical, alias_uri) do
    case Esr.Uri.alias(canonical, alias_uri) do
      :ok -> :ok
      {:error, :alias_exists} -> :ok
      other -> other
    end
  end

  defp extract_session_id(attrs) when is_map(attrs) do
    cond do
      is_binary(Map.get(attrs, :session_id)) ->
        Map.get(attrs, :session_id)

      is_list(Map.get(attrs, :session_ids)) ->
        List.first(Map.get(attrs, :session_ids))

      true ->
        nil
    end
  end
end

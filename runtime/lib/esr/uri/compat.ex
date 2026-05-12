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
  # Session + Agent wrappers — added in PR-3 / PR-4 as those domains
  # migrate. Not needed by PR-0 callers (no session/agent migration
  # work scheduled in PR-0).
  # ────────────────────────────────────────────────────────────
end

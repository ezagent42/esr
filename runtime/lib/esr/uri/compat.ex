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

  # ────────────────────────────────────────────────────────────
  # Session + Agent wrappers — added in PR-3 / PR-4 as those domains
  # migrate. Not needed by PR-0 callers (no session/agent migration
  # work scheduled in PR-0).
  # ────────────────────────────────────────────────────────────
end

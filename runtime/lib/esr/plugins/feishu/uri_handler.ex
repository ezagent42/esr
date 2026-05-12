defmodule Esr.Plugins.Feishu.UriHandler do
  @moduledoc """
  Feishu plugin URI handler. Owns the `esr://localhost/users/feishu/<ou_xxx>`
  subtree.

  PR-0 lifecycle note: today the handler calls the OLD
  `Esr.Entity.User.Registry.lookup_by_feishu_id/1` directly (which still
  exists in PR-0). PR-1 migrates User domain to URI store; at that point
  this handler is rewritten to read entity data via Esr.Uri.get_entity/1
  (still on the User canonical URI, not via the feishu alias — that
  would infinite-loop).

  Spec: docs/superpowers/specs/2026-05-12-uri-identity-design.md §6
  """

  @behaviour Esr.Uri.Plugin

  @impl Esr.Uri.Plugin
  def resolve(["ou_" <> _ = ou_id]) do
    # PR-0: read the old registry directly to avoid infinite recursion.
    case Esr.Entity.User.Registry.lookup_by_feishu_id(ou_id) do
      {:ok, username} ->
        # Translate username → UUID via the OLD NameIndex (PR-0 still
        # has both registries; PR-1 deletes them).
        case Esr.Entity.User.NameIndex.id_for_name(username) do
          {:ok, uuid} -> {:ok, "esr://localhost/users/" <> uuid}
          _ -> :not_found
        end

      _ ->
        :not_found
    end
  end

  def resolve(_), do: :invalid_format

  @impl Esr.Uri.Plugin
  def alias(canonical_user_uri, %{ou_id: ou_id})
      when is_binary(canonical_user_uri) and is_binary(ou_id) do
    alias_uri = "esr://localhost/users/feishu/" <> ou_id

    case Esr.Uri.alias(canonical_user_uri, alias_uri) do
      :ok -> {:ok, alias_uri}
      {:error, _} = err -> err
    end
  end
end

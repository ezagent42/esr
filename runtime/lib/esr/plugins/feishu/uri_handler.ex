defmodule Esr.Plugins.Feishu.UriHandler do
  @moduledoc """
  Feishu plugin URI handler. Owns the `esr://localhost/users/feishu/<ou_xxx>`
  subtree.

  PR-1 (2026-05-12 URI identity migration): User.Registry + User.NameIndex
  were deleted. FileLoader now writes a per-feishu_id alias row
  (`esr://localhost/users/feishu/<ou_id>` → canonical user URI) directly
  to `Esr.Uri.Store`. This handler does a single ETS lookup against that
  alias, no recursion through `Esr.Uri.resolve/1` (which would re-enter
  this same handler and infinite-loop).

  Spec: docs/superpowers/specs/2026-05-12-uri-identity-design.md §6
  """

  @behaviour Esr.Uri.Plugin

  @impl Esr.Uri.Plugin
  def resolve(["ou_" <> _ = ou_id]) do
    case Esr.Uri.Store.lookup_raw("esr://localhost/users/feishu/" <> ou_id) do
      {:ok, {:alias, "esr://localhost/users/" <> _ = canonical}} -> {:ok, canonical}
      _ -> :not_found
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

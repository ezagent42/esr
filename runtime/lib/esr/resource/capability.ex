defmodule Esr.Resource.Capability do
  @moduledoc """
  Public façade for the capabilities (access-control) subsystem.

  Permission = action name (e.g. "msg.send").
  Capability = (principal_id, permission) binding.

  ## Identity indirection

  A user can be identified in three forms across the system:

    * **Feishu `ou_*` open_id** — arrives on inbound envelopes from
      Feishu. Per-app (the same user has a different `ou_*` in each
      Feishu app they're in).
    * **`username`** — the canonical handle (`yao`, `linyilun`).
    * **UUID** — the canonical primary key written to `users.yaml` /
      `capabilities.yaml` (`b31e9dcc-...`).

  Caps in `capabilities.yaml` may be keyed by ANY of those three forms:

    * PR-21q bootstrap auto-grant keys by raw `ou_*` open_id (no
      esr-user exists yet at the first inbound).
    * The `auto_admin` path triggered by the first `user_add` (#282)
      keys by the user's freshly-minted UUID.
    * Operator CLI `esr cap grant <username> <perm>` translates to a
      UUID-keyed row via `Esr.Resource.Cap.UuidTranslator` at write
      time (since PR #348). Pre-PR-348 yaml files still on disk may
      carry username-keyed rows.

  The upstream pre-walkthrough-4 fix translated `ou_*` → UUID via
  `Esr.Uri.resolve("esr://localhost/users/feishu/<ou>")` so the
  canonical case (Feishu envelope → UUID-keyed grant) works. But it
  doesn't cover cross-form cases:

    * `ou_*` principal → username-keyed legacy row → miss
    * UUID principal (CLI submit) → username-keyed legacy row → miss
    * UUID principal → ou-keyed bootstrap row → miss
    * `ou_app1` principal → `ou_app2`-keyed row (multi-Feishu-app)
      → miss
    * Plain username principal (admin queue path) → UUID-keyed row
      → miss

  Walkthrough-4 PR-2 extends the lookup to N-form: after the direct
  hit misses, resolve the principal to its canonical user struct, then
  fan out to EVERY identifier form the user holds and re-check grants
  against each. Caps granted by any form apply regardless of which
  form arrives in the envelope.
  """

  alias Esr.Resource.Capability.Grants
  alias Esr.Uri.Compat

  @doc """
  Check whether principal holds the given permission (possibly via wildcard).

  Two-step lookup:
  1. Direct check on `principal_id` as given (catches the form the cap
     was granted in if it matches the envelope form).
  2. Otherwise: resolve `principal_id` to the canonical user across the
     URI store, gather every identifier form the user holds (UUID,
     username, all bound `ou_*`), and re-check `Grants.has?/2` against
     each.

  Falls through to `false` only when both steps miss.
  """
  @spec has?(String.t(), String.t()) :: boolean()
  def has?(principal_id, permission)
      when is_binary(principal_id) and is_binary(permission) do
    if Grants.has?(principal_id, permission) do
      true
    else
      principal_id
      |> other_identifiers()
      |> Enum.any?(&Grants.has?(&1, permission))
    end
  end

  @doc """
  Check whether the principal holds every permission in `perms`.

  Returns `:ok` when all permissions are held; `{:missing, [missing_perms]}`
  listing every permission the principal is missing. An empty list is
  trivially `:ok`.

  Used by `Esr.Commands.Session.New` (D18) to batch-verify the
  `capabilities_required` list materialized by
  `Esr.SessionTemplate.AgentDefBuilder` in one call.
  """
  @spec has_all?(String.t(), [String.t()]) :: :ok | {:missing, [String.t()]}
  def has_all?(principal_id, perms) when is_binary(principal_id) and is_list(perms) do
    case Enum.reject(perms, &has?(principal_id, &1)) do
      [] -> :ok
      missing -> {:missing, missing}
    end
  end

  # ------------------------------------------------------------------
  # Identity resolution
  # ------------------------------------------------------------------

  # Return every identifier form for the same user as `principal_id`
  # EXCEPT `principal_id` itself (already tried in step 1 by the
  # caller). Order doesn't matter — `Enum.any?/2` short-circuits.
  #
  # Empty list = either no esr-user is bound to `principal_id`, or the
  # URI store isn't running (test boot edge). Caller falls through to
  # `false`, preserving PR-21q's "raw open_id direct hit" behavior
  # when no user binding exists yet.
  defp other_identifiers(principal_id) do
    principal_id
    |> all_identifiers()
    |> Enum.reject(&(is_nil(&1) or &1 == principal_id))
    |> Enum.uniq()
  end

  defp all_identifiers(principal_id) do
    cond do
      String.starts_with?(principal_id, "ou_") ->
        identifiers_from_feishu_id(principal_id)

      looks_like_uuid?(principal_id) ->
        identifiers_from_uuid(principal_id)

      true ->
        identifiers_from_username(principal_id)
    end
  end

  defp identifiers_from_feishu_id(ou_id) do
    case Esr.Uri.resolve("esr://localhost/users/feishu/" <> ou_id) do
      {:ok, "esr://localhost/users/" <> uuid} ->
        username_from_uuid =
          case Compat.name_for_user_uuid(uuid) do
            {:ok, n} -> n
            _ -> nil
          end

        other_feishu =
          case Compat.user_by_uuid(uuid) do
            {:ok, %{feishu_ids: ids}} when is_list(ids) -> ids
            _ -> []
          end

        [uuid, username_from_uuid | other_feishu]

      _ ->
        []
    end
  end

  defp identifiers_from_uuid(uuid) do
    case Compat.user_by_uuid(uuid) do
      {:ok, %{username: username, feishu_ids: feishu_ids}} ->
        [username | feishu_ids || []]

      _ ->
        []
    end
  end

  defp identifiers_from_username(username) do
    uuid =
      case Compat.uuid_for_user_name(username) do
        {:ok, u} -> u
        _ -> nil
      end

    feishu_ids =
      case Compat.user_by_name(username) do
        {:ok, %{feishu_ids: ids}} when is_list(ids) -> ids
        _ -> []
      end

    [uuid | feishu_ids]
  end

  @uuid_re ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  defp looks_like_uuid?(s) when is_binary(s), do: Regex.match?(@uuid_re, s)
end

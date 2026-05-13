defmodule Esr.Resource.Capability do
  @moduledoc """
  Public façade for the capabilities (access-control) subsystem.

  Permission = action name (e.g. "msg.send").
  Capability = (principal_id, permission) binding.

  ## Identity indirection

  A user can be identified by three forms across the system:

    * **Feishu `ou_*` open_id** — arrives on inbound envelopes from
      Feishu. Per-app (the same person has a different `ou_*` in each
      Feishu app).
    * **`username`** — the canonical handle (`yao`, `linyilun`).
    * **UUID** — the canonical primary key written to disk
      (`b31e9dcc-...`).

  Caps in `capabilities.yaml` may be keyed by ANY of those three forms:

    * PR-21q bootstrap auto-grant keys by raw `ou_*` open_id (no
      esr-user exists yet at first inbound).
    * The `auto_admin` path triggered by the first `user_add` (#282)
      keys by the user's freshly-minted **UUID**.
    * Operator CLI `esr cap grant <username> <perm>` keys by
      **username**.

  Pre-PR-21s, `has?/2` did a direct ETS lookup against the raw key.
  PR-21s added one indirection: when `principal_id` was a Feishu
  `ou_*` and resolved to a username, also try the username grants.

  Walkthrough-4 (2026-05-12) C16 surfaced the missing third hop:
  when the cap row is UUID-keyed (auto_admin output) AND inbound
  `principal_id` is `ou_*`, the 2-hop chain (open_id → username)
  reaches "username" but no further — UUID-keyed grants are
  silently invisible. Symptom: chat-side `/session:new` returned
  `missing_capabilities` even though the user was admin.

  This module now does a full N-form lookup: step 1 tries the raw
  `principal_id`, step 2 resolves the user across the URI store and
  checks grants against every OTHER identifier form the same user
  holds (UUID, username, every bound `ou_*`). Caps granted by any
  form apply regardless of which form arrives in the envelope.

  The URI-store lookups (`Esr.Uri.Compat.*`) are :not_found-safe so
  test boot paths without a populated store fall back to direct-grant
  semantics, preserving PR-21q's bootstrap behavior.
  """

  alias Esr.Resource.Capability.Grants
  alias Esr.Uri.Compat

  @doc """
  Check whether principal holds the given permission (possibly via wildcard).

  Two-step lookup:
  1. Direct check on `principal_id` as given. Catches the form the cap
     was granted in if it matches the envelope form.
  2. Otherwise: resolve `principal_id` to canonical user, gather every
     identifier form (UUID, username, all bound `ou_*`), and check
     grants against each.
  """
  @spec has?(String.t(), String.t()) :: boolean()
  def has?(principal_id, permission)
      when is_binary(principal_id) and is_binary(permission) do
    if Grants.has?(principal_id, permission) do
      true
    else
      Enum.any?(other_identifiers(principal_id), &Grants.has?(&1, permission))
    end
  end

  @doc """
  Check whether the principal holds every permission in `perms`.

  Returns `:ok` when all permissions are held; `{:missing, [missing_perms]}`
  listing every permission the principal is missing. An empty list is
  trivially `:ok`.

  Used by `Esr.Commands.Session.New` (D18) to batch-verify the
  `capabilities_required` list materialized by
  `Esr.SessionTemplate.AgentDefBuilder` (which sources caps from each
  plugin's manifest `agent_kinds[].capabilities_required` block —
  Phase 6, 2026-05-10) in one call, so the error payload can enumerate
  every missing cap at once (not just the first one).
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

  # Form-detect `principal_id` and resolve the canonical user's full
  # identifier triple `(uuid, username, feishu_ids)`. Each branch
  # tolerates :not_found at any step — partial resolution still
  # contributes whichever identifiers we did find.
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
    case Compat.username_for_feishu_id(ou_id) do
      {:ok, username} ->
        uuid =
          case Compat.uuid_for_user_name(username) do
            {:ok, u} -> u
            :not_found -> nil
          end

        # Same user may be bound to additional ou_* (multi-Feishu-app).
        # Pull them from the User struct so caps granted via any of
        # the user's open_ids reach this lookup too.
        other_feishu_ids =
          case Compat.user_by_name(username) do
            {:ok, %{feishu_ids: ids}} when is_list(ids) -> ids
            _ -> []
          end

        [username, uuid | other_feishu_ids]

      :not_found ->
        []
    end
  end

  defp identifiers_from_uuid(uuid) do
    case Compat.user_by_uuid(uuid) do
      {:ok, %{username: username, feishu_ids: feishu_ids}} ->
        feishu_ids = feishu_ids || []
        [username | feishu_ids]

      _ ->
        []
    end
  end

  defp identifiers_from_username(username) do
    case Compat.user_by_name(username) do
      {:ok, %{feishu_ids: feishu_ids}} ->
        feishu_ids = feishu_ids || []

        uuid =
          case Compat.uuid_for_user_name(username) do
            {:ok, u} -> u
            :not_found -> nil
          end

        [uuid | feishu_ids]

      _ ->
        # Even if the User struct is not found, the username → UUID
        # lookup may still succeed (different store paths). Keep
        # whatever the name-index can give us so UUID-keyed grants
        # remain reachable when arriving via username form.
        case Compat.uuid_for_user_name(username) do
          {:ok, u} -> [u]
          :not_found -> []
        end
    end
  end

  @uuid_re ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  defp looks_like_uuid?(s) when is_binary(s), do: Regex.match?(@uuid_re, s)
end

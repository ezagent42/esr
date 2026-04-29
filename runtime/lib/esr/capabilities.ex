defmodule Esr.Capabilities do
  @moduledoc """
  Public façade for the capabilities (access-control) subsystem.

  Permission = action name (e.g. "msg.send").
  Capability = (principal_id, permission) binding.

  PR-21s (2026-04-29): when `principal_id` is a Feishu `ou_*` open_id
  AND the open_id is bound to an esr user via `Esr.Users.Registry`,
  cap checks ALSO consult the bound esr-username's caps. This lets
  operators grant caps by esr-username (`esr cap grant linyilun admin`)
  and have them apply to inbound envelopes that still carry the raw
  open_id as principal_id. Pre-PR-21s, caps were strictly indexed by
  principal_id string with no resolution.
  """

  @doc """
  Check whether principal holds the given permission (possibly via wildcard).

  Two-step lookup (PR-21s):
  1. Direct check on `principal_id` (catches caps granted by raw open_id
     during bootstrap, e.g. PR-21q's auto-grant).
  2. If miss AND `Esr.Users.Registry` resolves `principal_id` to an esr
     username, retry the cap check against the username (catches caps
     granted by `esr cap grant <username> <perm>`).

  Falls through to `false` only when both miss. The Users.Registry
  lookup is skipped when the registry isn't running (tests / boot edge),
  preserving backward-compat with the pre-PR-21s direct-only behaviour.
  """
  @spec has?(String.t(), String.t()) :: boolean()
  def has?(principal_id, permission)
      when is_binary(principal_id) and is_binary(permission) do
    if Esr.Capabilities.Grants.has?(principal_id, permission) do
      true
    else
      case maybe_resolve_to_username(principal_id) do
        {:ok, username} when username != principal_id ->
          Esr.Capabilities.Grants.has?(username, permission)

        _ ->
          false
      end
    end
  end

  defp maybe_resolve_to_username(principal_id) do
    if Process.whereis(Esr.Users.Registry) do
      Esr.Users.Registry.lookup_by_feishu_id(principal_id)
    else
      :not_found
    end
  end

  @doc """
  Check whether the principal holds every permission in `perms`.

  Returns `:ok` when all permissions are held; `{:missing, [missing_perms]}`
  listing every permission the principal is missing. An empty list is
  trivially `:ok`.

  Used by `Esr.Admin.Commands.Session.New` (D18) to batch-verify the
  `capabilities_required` list from `agents.yaml` in one call, so the
  error payload can enumerate every missing cap at once (not just the
  first one).
  """
  @spec has_all?(String.t(), [String.t()]) :: :ok | {:missing, [String.t()]}
  def has_all?(principal_id, perms) when is_binary(principal_id) and is_list(perms) do
    case Enum.reject(perms, &has?(principal_id, &1)) do
      [] -> :ok
      missing -> {:missing, missing}
    end
  end
end

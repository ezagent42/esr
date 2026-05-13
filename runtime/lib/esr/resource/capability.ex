defmodule Esr.Resource.Capability do
  @moduledoc """
  Public façade for the capabilities (access-control) subsystem.

  Permission = action name (e.g. "msg.send").
  Capability = (principal_id, permission) binding.

  When `principal_id` is a Feishu `ou_*` open_id bound to an esr user,
  cap checks resolve open_id → canonical UUID via the URI store and retry
  against the UUID. capabilities.yaml stores caps keyed by UUID (since
  PR-348 / Cap.UuidTranslator translates `esr cap grant <name>` to UUID
  at write time), so the fallback must produce a UUID, not a username.
  """

  @doc """
  Check whether principal holds the given permission (possibly via wildcard).

  Two-step lookup:
  1. Direct check on `principal_id` (catches caps granted by raw open_id
     during bootstrap, e.g. PR-21q's auto-grant before user_add).
  2. If miss AND the URI store resolves `esr://localhost/users/feishu/<id>`
     to a canonical user URI, retry against the embedded UUID.

  Falls through to `false` only when both miss.
  """
  @spec has?(String.t(), String.t()) :: boolean()
  def has?(principal_id, permission)
      when is_binary(principal_id) and is_binary(permission) do
    if Esr.Resource.Capability.Grants.has?(principal_id, permission) do
      true
    else
      case maybe_resolve_to_uuid(principal_id) do
        {:ok, uuid} when uuid != principal_id ->
          Esr.Resource.Capability.Grants.has?(uuid, permission)

        _ ->
          false
      end
    end
  end

  defp maybe_resolve_to_uuid(principal_id) do
    case Esr.Uri.resolve("esr://localhost/users/feishu/" <> principal_id) do
      {:ok, "esr://localhost/users/" <> uuid} -> {:ok, uuid}
      _ -> :not_found
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
end

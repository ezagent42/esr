defmodule Esr.Capabilities do
  @moduledoc """
  Public façade for the capabilities (access-control) subsystem.

  Permission = action name (e.g. "msg.send").
  Capability = (principal_id, permission) binding.
  """

  @doc "Check whether principal holds the given permission (possibly via wildcard)."
  defdelegate has?(principal_id, permission), to: Esr.Capabilities.Grants

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

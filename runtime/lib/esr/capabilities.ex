defmodule Esr.Capabilities do
  @moduledoc """
  Public façade for the capabilities (access-control) subsystem.

  Permission = action name (e.g. "msg.send").
  Capability = (principal_id, permission) binding.
  """

  @doc "Check whether principal holds the given permission (possibly via wildcard)."
  defdelegate has?(principal_id, permission), to: Esr.Capabilities.Grants
end

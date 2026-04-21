defmodule Esr.Permissions do
  @moduledoc "Public façade for the permissions subsystem."
  defdelegate all(), to: Esr.Permissions.Registry
  defdelegate declared?(name), to: Esr.Permissions.Registry
  defdelegate register(name, opts), to: Esr.Permissions.Registry
end

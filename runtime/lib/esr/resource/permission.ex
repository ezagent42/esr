defmodule Esr.Resource.Permission do
  @moduledoc "Public façade for the permissions subsystem."
  defdelegate all(), to: Esr.Resource.Permission.Registry
  defdelegate declared?(name), to: Esr.Resource.Permission.Registry
  defdelegate register(name, opts), to: Esr.Resource.Permission.Registry
end

defmodule Esr.Topology.Supervisor do
  @moduledoc """
  Supervises Topology subsystem (Registry and Instantiator). Spec §3.5.
  Scaffold for F02 — children arrive in F13+.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init([], strategy: :one_for_one)
  end
end

defmodule Esr.Persistence.Supervisor do
  @moduledoc """
  Supervises ETS-backed actor-state persistence (PRD 01 F18, spec §3.1).
  Hosts `Esr.Persistence.Ets` keyed by table `:esr_actor_states`.
  Entity.Server reads/writes this table; restart-survival (Track G-4)
  re-hydrates from disk via `Esr.Persistence.Ets.load_from_disk/2`.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    children = [
      {Esr.Persistence.Ets, name: Esr.Persistence.Ets, table: :esr_actor_states}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Esr.Persistence.Supervisor do
  @moduledoc """
  Supervises ETS-backed state persistence (spec §3.1, §3.8 config dir).
  Scaffold for F02 — children arrive in F18.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init([], strategy: :one_for_one)
  end
end

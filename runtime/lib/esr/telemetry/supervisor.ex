defmodule Esr.Telemetry.Supervisor do
  @moduledoc """
  Supervises the :telemetry buffer and any attached handlers (spec §3.6).
  Scaffold for F02 — Buffer arrives in F15, attach handlers in F16.

  Note: this is distinct from `EsrWeb.Telemetry` (the Phoenix-generated
  VM metrics endpoint, kept for phoenix defaults). Our subsystem owns
  ESR-specific events only.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init([], strategy: :one_for_one)
  end
end

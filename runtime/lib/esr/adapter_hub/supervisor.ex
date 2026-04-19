defmodule Esr.AdapterHub.Supervisor do
  @moduledoc """
  Supervises AdapterHub children (Registry and, later, adapter session
  processes). Spec §3.3. Scaffold for F02 — children arrive in F08+.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init([], strategy: :one_for_one)
  end
end

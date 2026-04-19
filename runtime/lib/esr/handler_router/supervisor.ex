defmodule Esr.HandlerRouter.Supervisor do
  @moduledoc """
  Supervises HandlerRouter children (pool manager and, later, per-module
  worker pools). Spec §3.4. Scaffold for F02 — children arrive in F10+.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init([], strategy: :one_for_one)
  end
end

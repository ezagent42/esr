defmodule Esr.PeerSupervisor do
  @moduledoc """
  DynamicSupervisor for PeerServer processes. One-for-one strategy so
  one actor crashing never cascades to sibling actors (spec §3.2, §5
  isolation invariant).

  v0.1 scaffold — `start_peer/1` and `stop_peer/1` land in PRD 01 F04.
  This module is created in F02 so the Application supervision tree can
  reference it.
  """
  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end

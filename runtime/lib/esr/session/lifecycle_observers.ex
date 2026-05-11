defmodule Esr.Session.LifecycleObservers do
  @moduledoc """
  Top-level DynamicSupervisor for `Esr.Session.LifecycleObserver`
  children. Lives in the application tree at the SAME LEVEL as
  `Esr.Session.Supervisor` — NOT under it — so observers survive the
  per-session subtree they're watching. ADR-0002 records why.

  One observer child per active session, restart strategy `:temporary`
  (the observer dies on purpose with `:normal` after the watched
  supervisor DOWN fires; restarting would re-monitor a dead pid + spam
  the chat).

  Plan: PR-3 Task 3.7.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Start a `LifecycleObserver` child for the given session. Called from
  `Esr.Session.AgentSpawner.do_create/1` after `verify_pipeline_complete/2`
  succeeds.
  """
  @spec start_observer(Esr.Session.LifecycleObserver.args()) ::
          DynamicSupervisor.on_start_child()
  def start_observer(args) when is_map(args) do
    spec = %{
      id: Esr.Session.LifecycleObserver,
      start: {Esr.Session.LifecycleObserver, :start_link, [args]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end

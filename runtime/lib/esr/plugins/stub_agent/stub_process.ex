defmodule Esr.Plugins.StubAgent.StubProcess do
  @moduledoc """
  Minimal stateful peer for the `stub_agent` plugin (Phase 8 Task 8.5).

  Init returns `{:ok, %{}}`; no actual logic. The peer exists so the
  agent_kind's pipeline.inbound can reference a real module — proves the
  SessionTemplate machinery doesn't hardcode CC-specific peer modules.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  Phase 8.
  """

  use GenServer

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(_msg, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_cast(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}
end

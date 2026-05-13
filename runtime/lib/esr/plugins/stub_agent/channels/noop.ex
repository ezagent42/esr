defmodule Esr.Plugins.StubAgent.Channels.NoOp do
  @moduledoc """
  No-op Channel impl for the `stub_agent` plugin (Phase 8 Task 8.5).

  Mirrors `Esr.Plugins.ClaudeCode.Channels.Mcp`'s minimal structure:
  `start_link/1`, `dispatch/2` (no-op), `subscribe/3` (records listener),
  `config_schema/0`. State is intentionally trivial — this Channel exists
  to prove the abstraction is generic, not to do real I/O.

  Per-session lifecycle peer; supervised under per-session
  `AgentInstanceSupervisor` once a SessionTemplate referencing
  `stub_agent.noop` is materialized.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  Phase 8.
  """

  @behaviour Esr.Channel

  use GenServer

  require Logger

  # ------------------------------------------------------------------
  # Esr.Channel callbacks
  # ------------------------------------------------------------------

  @impl Esr.Channel
  def start_link(opts) when is_list(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: name_for(session_id))
  end

  @impl Esr.Channel
  def dispatch(pid, msg) when is_pid(pid) do
    GenServer.call(pid, {:dispatch, msg})
  end

  @impl Esr.Channel
  def subscribe(pid, listener_pid, topic) when is_pid(pid) and is_pid(listener_pid) do
    GenServer.call(pid, {:subscribe, listener_pid, topic})
  end

  @impl Esr.Channel
  def config_schema do
    %{
      "type" => "object",
      "properties" => %{}
    }
  end

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.get(opts, :config, %{})

    {:ok,
     %{
       session_id: session_id,
       config: config,
       # %{topic_key => [listener_pid, ...]}
       subscribers: %{},
       # count dispatches received — useful for tests
       dispatched_count: 0
     }}
  end

  @impl GenServer
  def handle_call({:dispatch, _msg}, _from, state) do
    # No-op. Real Channels would route the message to the wire transport.
    {:reply, :ok, %{state | dispatched_count: state.dispatched_count + 1}}
  end

  def handle_call({:subscribe, listener_pid, topic}, _from, state) do
    new_subs = Map.update(state.subscribers, topic, [listener_pid], &[listener_pid | &1])
    {:reply, :ok, %{state | subscribers: new_subs}}
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp name_for(session_id) when is_binary(session_id) do
    {:via, Registry, {Esr.Channel.Instances, "stub_agent.noop:" <> session_id}}
  end
end

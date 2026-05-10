defmodule Esr.Plugins.ClaudeCode.Channels.McpHttp do
  @moduledoc """
  Wraps the existing Elixir MCP HTTP transport (`EsrWeb.McpController` +
  `cli:channel/<sid>` PubSub topic) under the `Esr.Channel` behaviour.

  Per-session lifecycle peer; supervised under per-session
  `AgentInstanceSupervisor` once Phase 4's SessionTemplate loader spawns
  it. Until then the module is callable directly via `start_link/1` for
  tests + ad-hoc use.

  ## Adapter discipline

  No new transport code. `EsrWeb.McpController` continues to handle
  HTTP/SSE; `cc_mcp` (Python side) continues to subscribe to
  `cli:channel/<sid>` and announce readiness on `cc_mcp_ready/<sid>`.
  This module is the addressable Channel pid for SessionTemplate loaders
  (Phase 4) — `dispatch/2` forwards to the existing PubSub topic;
  `subscribe/3` registers a listener pid + topic key in state and the
  GenServer forwards lifecycle events (today: `:ready`).

  ## Naming

  Registered via `{:via, Registry, {Esr.Channel.Instances,
  "claude_code.mcp_http:<session_id>"}}` so the SessionTemplate loader
  can `Registry.lookup/2` the live pid for any session. Mirrors how
  `Esr.Session.supervisor_name/1` resolves a session_sup pid via
  `Esr.Session.Registry`.

  History: 2026-05-10 spec
  `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`,
  Phase 2.
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
      "properties" => %{
        "port" => %{"type" => "integer"}
      }
    }
  end

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.get(opts, :config, %{})

    # Subscribe to the existing cc_mcp_ready signal so we can forward to
    # any listener that calls `subscribe(pid, self(), :ready)`. The
    # `EsrWeb.PubSub` registration is mandatory; if it's missing we'd
    # rather crash here than silently degrade (let-it-crash).
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "cc_mcp_ready/" <> session_id)

    {:ok,
     %{
       session_id: session_id,
       config: config,
       cc_mcp_ready: false,
       # %{topic_key => [listener_pid, ...]}. Order is reverse-chrono;
       # we don't care since `send/2` is non-ordered to multiple pids.
       subscribers: %{}
     }}
  end

  @impl GenServer
  def handle_call({:dispatch, msg}, _from, %{session_id: sid} = state) do
    Phoenix.PubSub.broadcast(EsrWeb.PubSub, "cli:channel/" <> sid, msg)
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, listener_pid, topic}, _from, state) do
    new_subs = Map.update(state.subscribers, topic, [listener_pid], &[listener_pid | &1])
    {:reply, :ok, %{state | subscribers: new_subs}}
  end

  @impl GenServer
  def handle_info({:cc_mcp_ready, sid}, %{session_id: sid} = state) do
    Logger.info("McpHttp channel: cc_mcp ready for session #{sid}")

    for listener <- Map.get(state.subscribers, :ready, []) do
      send(listener, {:cc_mcp_ready, sid})
    end

    {:noreply, %{state | cc_mcp_ready: true}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp name_for(session_id) when is_binary(session_id) do
    {:via, Registry, {Esr.Channel.Instances, "claude_code.mcp_http:" <> session_id}}
  end
end

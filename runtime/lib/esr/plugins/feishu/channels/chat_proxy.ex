defmodule Esr.Plugins.Feishu.Channels.ChatProxy do
  @moduledoc """
  Per-session Feishu chat Channel — the addressable lifecycle peer that
  SessionTemplate (Phase 4) will spawn under the per-session
  `AgentInstanceSupervisor`. Mirrors the `Esr.Plugins.ClaudeCode.Channels.Mcp`
  pattern: a SEPARATE GenServer adapter under the `Esr.Channel` behaviour
  that wraps existing transport infrastructure without moving it.

  ## Adapter discipline

  This module does NOT subsume `Esr.Plugins.Feishu.FeishuChatProxy` (FCP).
  FCP keeps its full responsibility — agent-router half (mention parser,
  primary routing, tool_invoke dispatch, react/un-react) AND its current
  inbound/outbound message handling — unchanged. This Channel exists
  alongside FCP solely to give SessionTemplate loaders an addressable
  `Esr.Channel`-shaped pid per the spec's three-layer model.

  Concretely:

  - `dispatch/2` broadcasts on `feishu_outbound/<session_id>` — a NEW
    topic introduced by this Channel. Whatever FAA / FeishuAppProxy
    plumbing chooses to subscribe (in Phase 4 wiring) consumes from
    this topic for wire delivery. Today no producer-of-FCP-side wires
    to it; the topic is the future-facing seam.

  - `init/1` subscribes to `feishu_inbound/<session_id>` — also a NEW
    topic. When Phase 4 routes inbound Feishu envelopes through the
    Channel layer instead of (or in addition to) the existing
    `send(fcp_pid, {:feishu_inbound, ...})` direct send, broadcasts
    on this topic land here and forward to listeners under the
    `:inbound` topic key.

  - Registered via `{:via, Registry, {Esr.Channel.Instances,
    "feishu.chat_proxy:" <> session_id}}` so SessionTemplate can
    `Registry.lookup/2` the live pid.

  ## Naming

  `feishu.chat_proxy` matches the `<plugin>.<channel_name>` convention
  used by `Esr.Channel.Registry` and the Mcp impl
  (`claude_code.mcp_stdio`).

  History: 2026-05-10 spec
  `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`,
  Phase 3.
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

    # Subscribe to the inbound topic so any future producer (e.g. a
    # SessionTemplate-driven inbound dispatcher) broadcasting
    # `{:feishu_inbound_event, envelope}` lands in this peer's mailbox.
    # `EsrWeb.PubSub` is mandatory at runtime; if it's missing we'd
    # rather crash here than silently degrade (let-it-crash).
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "feishu_inbound/" <> session_id)

    {:ok,
     %{
       session_id: session_id,
       config: config,
       # %{topic_key => [listener_pid, ...]}. Order is reverse-chrono;
       # we don't care since `send/2` is non-ordered to multiple pids.
       subscribers: %{}
     }}
  end

  @impl GenServer
  def handle_call({:dispatch, msg}, _from, %{session_id: sid} = state) do
    Phoenix.PubSub.broadcast(EsrWeb.PubSub, "feishu_outbound/" <> sid, msg)
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, listener_pid, topic}, _from, state) do
    new_subs = Map.update(state.subscribers, topic, [listener_pid], &[listener_pid | &1])
    {:reply, :ok, %{state | subscribers: new_subs}}
  end

  @impl GenServer
  def handle_info({:feishu_inbound_event, sid, _envelope} = msg, %{session_id: sid} = state) do
    Logger.debug("feishu chat_proxy channel: inbound event for session #{sid}")

    for listener <- Map.get(state.subscribers, :inbound, []) do
      send(listener, msg)
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp name_for(session_id) when is_binary(session_id) do
    {:via, Registry, {Esr.Channel.Instances, "feishu.chat_proxy:" <> session_id}}
  end
end

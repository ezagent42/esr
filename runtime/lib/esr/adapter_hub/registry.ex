defmodule Esr.AdapterHub.Registry do
  @moduledoc """
  Binds adapter Phoenix topics (`adapter:<name>/<instance_id>`) to the
  actor_id that owns them (PRD 01 F08, spec §3.3). When an inbound
  event arrives on a Phoenix channel, `AdapterHub` uses this registry
  to find the owning PeerServer.

  Backed by ETS (not Elixir's `Registry`) because the keys are long-
  lived URL-like strings, not process names, and we want cheap
  atomic upsert semantics.

  Public API:
    start_link/1              — no opts; named by module
    bind(topic, actor_id)     — upsert; returns :ok
    unbind(topic)             — idempotent; returns :ok
    lookup(topic)             — {:ok, actor_id} | :error
    list/0                    — [{topic, actor_id}]

  Reviewer S5: the GenServer now monitors every bound actor's pid
  (resolved through `Esr.PeerRegistry`). When the pid goes down,
  every binding owned by it is removed from the ETS table so ghost
  entries don't accumulate.
  """
  use GenServer

  @table :esr_adapter_hub_bindings

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec bind(String.t(), String.t()) :: :ok
  def bind(topic, actor_id) when is_binary(topic) and is_binary(actor_id) do
    GenServer.call(__MODULE__, {:bind, topic, actor_id})
  end

  @spec unbind(String.t()) :: :ok
  def unbind(topic) when is_binary(topic) do
    GenServer.call(__MODULE__, {:unbind, topic})
  end

  @spec lookup(String.t()) :: {:ok, String.t()} | :error
  def lookup(topic) when is_binary(topic) do
    case :ets.lookup(@table, topic) do
      [{^topic, actor_id}] -> {:ok, actor_id}
      [] -> :error
    end
  end

  @spec list() :: [{String.t(), String.t()}]
  def list, do: :ets.tab2list(@table)

  # ------------------------------------------------------------------
  # GenServer
  # ------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{topics_by_ref: %{}, ref_by_pid: %{}, topic_to_ref: %{}}}
  end

  @impl GenServer
  def handle_call({:bind, topic, actor_id}, _from, state) do
    # Drop any stale monitor pointing at the old owner of this topic.
    state = drop_topic(state, topic)

    :ets.insert(@table, {topic, actor_id})

    state =
      case Esr.PeerRegistry.lookup(actor_id) do
        {:ok, pid} -> track_pid(state, pid, topic)
        :error -> state
      end

    {:reply, :ok, state}
  end

  def handle_call({:unbind, topic}, _from, state) do
    :ets.delete(@table, topic)
    {:reply, :ok, drop_topic(state, topic)}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {topics, rest_by_ref} = Map.pop(state.topics_by_ref, ref, [])

    for t <- topics, do: :ets.delete(@table, t)

    rest_by_pid =
      state.ref_by_pid
      |> Enum.reject(fn {_pid, r} -> r == ref end)
      |> Map.new()

    rest_topic_to_ref = Map.drop(state.topic_to_ref, topics)

    {:noreply,
     %{state | topics_by_ref: rest_by_ref, ref_by_pid: rest_by_pid, topic_to_ref: rest_topic_to_ref}}
  end

  # ------------------------------------------------------------------
  # internals
  # ------------------------------------------------------------------

  defp track_pid(state, pid, topic) do
    {ref, ref_by_pid} =
      case Map.fetch(state.ref_by_pid, pid) do
        {:ok, existing} -> {existing, state.ref_by_pid}
        :error ->
          ref = Process.monitor(pid)
          {ref, Map.put(state.ref_by_pid, pid, ref)}
      end

    topics_by_ref = Map.update(state.topics_by_ref, ref, [topic], &[topic | &1])
    topic_to_ref = Map.put(state.topic_to_ref, topic, ref)

    %{state | topics_by_ref: topics_by_ref, ref_by_pid: ref_by_pid, topic_to_ref: topic_to_ref}
  end

  defp drop_topic(state, topic) do
    case Map.pop(state.topic_to_ref, topic) do
      {nil, _} ->
        state

      {ref, rest_topic_to_ref} ->
        topics_by_ref =
          Map.update(state.topics_by_ref, ref, [], fn topics ->
            List.delete(topics, topic)
          end)

        %{state | topics_by_ref: topics_by_ref, topic_to_ref: rest_topic_to_ref}
    end
  end
end

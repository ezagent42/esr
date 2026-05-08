defmodule Esr.Entity.Registry.IndexWatcher do
  @moduledoc """
  Companion GenServer for `Esr.Entity.Registry`'s ETS indexes (M-1).

  Owns two named ETS tables and cleans them on monitor DOWN:

    * `:esr_actor_name_index` — `set`; `{session_id, name} → {pid, actor_id}`
    * `:esr_actor_role_index` — `bag`; `{session_id, role} → {pid, actor_id}`

  Both tables are created in `init/1` so that all writers
  (`Esr.Entity.Registry.register_attrs/2`) are guaranteed a live table
  to insert into from the moment the supervision tree comes up.

  ## Why a GenServer here

  `register_attrs/2` calls `Process.monitor/1` on the registrant; the
  resulting DOWN message needs a stable receiver so Index 2/3 entries
  for crashed peers don't pile up. The host `Elixir.Registry` GenServer
  registered as `Esr.Entity.Registry` cannot be extended with a custom
  `handle_info/2`, so we run a thin companion process. The companion
  also owns the ETS tables — matching the established pattern in
  `Esr.Resource.Workspace.NameIndex` (one GenServer, multiple ETS
  tables) — so we don't need a separate ad-hoc table-owner process.

  ## Cleanup metadata

  We carry an in-memory `monitor_ref → metadata` map so DOWN cleanup is
  O(1) per dead peer. The ETS tables are not scanned on DOWN.
  """

  use GenServer

  @name_index :esr_actor_name_index
  @role_index :esr_actor_role_index

  @doc false
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Set up `Process.monitor/1` from inside the IndexWatcher process and
  associate the resulting monitor reference with the supplied cleanup
  metadata.

  This is a synchronous `call/3` — the monitor MUST be in place before
  `Esr.Entity.Registry.register_attrs/2` returns, otherwise the
  registrant could die between returning and the watcher noticing,
  leaking entries. By running `Process.monitor/1` inside this
  GenServer, the DOWN message is also delivered here (to the right
  mailbox), which the cast-based approach in earlier drafts could not
  guarantee.
  """
  @spec monitor_and_track(%{
          pid: pid(),
          actor_id: String.t(),
          session_id: String.t(),
          name: String.t(),
          role: atom()
        }) :: :ok
  def monitor_and_track(metadata) when is_map(metadata) do
    GenServer.call(__MODULE__, {:monitor_and_track, metadata})
  end

  # ----------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Tables are :public + :named so writers (peer GenServers running
    # outside this process) can do their own :ets.insert / lookup
    # without funnelling through this process's mailbox. read_concurrency
    # is enabled because lookups vastly outnumber writes.
    _ = ensure_table(@name_index, [:named_table, :set, :public, read_concurrency: true])

    _ =
      ensure_table(@role_index, [
        :named_table,
        :bag,
        :public,
        read_concurrency: true
      ])

    {:ok, %{monitors: %{}}}
  end

  defp ensure_table(name, opts) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, opts)
    else
      name
    end
  end

  @impl true
  def handle_call({:monitor_and_track, %{pid: pid} = metadata}, _from, %{monitors: monitors} = state) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | monitors: Map.put(monitors, ref, metadata)}}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{monitors: monitors} = state
      ) do
    case Map.pop(monitors, ref) do
      {nil, _} ->
        # Unknown monitor reference; ignore (could be a duplicate DOWN
        # delivery after explicit deregister_attrs/2 demoted the entry,
        # though Process.monitor itself never re-fires).
        {:noreply, state}

      {%{
         actor_id: aid,
         session_id: sid,
         name: name,
         role: role,
         pid: dead_pid
       }, remaining} ->
        :ets.delete(@name_index, {sid, name})
        :ets.match_delete(@role_index, {{sid, role}, {dead_pid, aid}})
        {:noreply, %{state | monitors: remaining}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}
end

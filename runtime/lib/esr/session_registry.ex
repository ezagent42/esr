defmodule Esr.SessionRegistry do
  @moduledoc """
  Tracks live CC session ↔ WebSocket bindings (spec §3.2).

  State row per session_id:
    %{ws_pid, chat_ids, app_ids, workspace,
      principal_id, workspace_name,
      status: :online | :offline, last_seen_ms}

  ``principal_id`` + ``workspace_name`` (capabilities spec §6.2/§6.3):
  captured when the CC worker sends ``session_register``. Both default
  to ``nil`` when the frame doesn't supply them (e.g. pre-capabilities
  clients); Lane B will fall back to the bootstrap principal for
  tool_invoke dispatch.

  Backed by a named GenServer + ETS public set so reads are
  concurrent / lock-free; writes serialise through the GenServer to
  keep "new wins" eviction + monitor bookkeeping consistent (§6.2b).

  Reviewer S1: peer_pid is intentionally NOT in the registry row.
  Earlier spec drafts suggested storing it here; the v0.2 implementation
  uses `Registry.lookup(Esr.PeerRegistry, "thread:<sid>")` in
  ChannelChannel.handle_in(tool_invoke) as the authoritative lookup.
  Storing peer_pid in two places would risk drift.
  """
  use GenServer

  @table :esr_session_registry

  # ----- Public API -----
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec register(String.t(), keyword()) :: :ok
  def register(session_id, opts) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:register, session_id, Map.new(opts)})
  end

  @spec mark_offline(String.t()) :: :ok
  def mark_offline(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:mark_offline, session_id})
  end

  @spec lookup(String.t()) :: {:ok, map()} | :error
  def lookup(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, row}] -> {:ok, row}
      [] -> :error
    end
  end

  @spec list() :: [{String.t(), map()}]
  def list, do: :ets.tab2list(@table)

  @spec notify_session(String.t(), map()) ::
          :ok | {:error, :offline} | {:error, :not_registered}
  def notify_session(session_id, envelope) when is_binary(session_id) and is_map(envelope) do
    case lookup(session_id) do
      {:ok, %{status: :online, ws_pid: ws_pid}} ->
        send(ws_pid, {:push_envelope, envelope})
        :ok

      {:ok, %{status: :offline}} -> {:error, :offline}
      :error -> {:error, :not_registered}
    end
  end

  # ----- GenServer -----
  @impl GenServer
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:register, sid, row_fields}, _from, state) do
    row =
      row_fields
      |> Map.take([
        :ws_pid,
        :chat_ids,
        :app_ids,
        :workspace,
        :principal_id,
        :workspace_name
      ])
      |> Map.put(:status, :online)
      |> Map.put(:last_seen_ms, System.system_time(:millisecond))

    :ets.insert(@table, {sid, row})
    {:reply, :ok, state}
  end

  def handle_call({:mark_offline, sid}, _from, state) do
    case :ets.lookup(@table, sid) do
      [{^sid, row}] ->
        :ets.insert(@table, {sid, %{row | status: :offline,
                                           last_seen_ms: System.system_time(:millisecond)}})
      [] -> :ok
    end
    {:reply, :ok, state}
  end
end

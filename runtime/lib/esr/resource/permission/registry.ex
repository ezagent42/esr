defmodule Esr.Resource.Permission.Registry do
  @moduledoc """
  ETS-backed catalog of declared permissions.

  Populated at boot from handler/adapter `permissions/0` callbacks and
  the Python handler_hello IPC envelope. Frozen after boot (writes
  disabled once `Esr.Resource.Capability.Grants` has loaded the capability
  file, to prevent late additions from invalidating prior validation).
  """

  @behaviour Esr.Role.State
  use GenServer

  @table :esr_permissions_registry

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def register(name, opts) when is_binary(name) do
    GenServer.call(__MODULE__, {:register, name, Keyword.get(opts, :declared_by)})
  end

  def declared?(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [] -> false
      [_] -> true
    end
  end

  def all do
    :ets.tab2list(@table) |> Enum.map(fn {name, _} -> name end)
  end

  # PR-4.4: dump_json/1 deleted. The JSON snapshot at
  # `~/.esrd/<env>/permissions_registry.json` was consumed only by
  # `py/src/esr/cli/cap.py` for offline pretty-print of `esr cap list`.
  # Phase 2 introduced the Elixir-native `esr exec /cap list` path
  # which reads the in-memory registry via slash dispatch directly,
  # making the cross-process file dump redundant. Python `esr cap
  # list` still reads any pre-existing file but data ages until
  # PR-4.6/4.7 ports / deletes the Python CLI.

  @doc false
  # Test-only: wipe all registrations. Not exposed via the façade.
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, name, declared_by}, _from, state) do
    :ets.insert(@table, {name, declared_by})
    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end
end

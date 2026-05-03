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

  @doc """
  Write a JSON snapshot of registered permissions to `path`, grouped by
  the declaring module.

  Output shape: `{"Elixir.Mod.Name": ["perm.a", "perm.b"], ...}` —
  consumed by `esr cap list` (py/src/esr/cli/cap.py). This is a
  one-shot snapshot taken at the end of bootstrap; the file is not
  touched again at runtime.
  """
  @spec dump_json(Path.t()) :: :ok
  def dump_json(path) do
    entries =
      :ets.tab2list(@table)
      |> Enum.group_by(
        fn {_name, declared_by} -> to_string(declared_by) end,
        fn {name, _} -> name end
      )

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(entries, pretty: true))
    :ok
  end

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

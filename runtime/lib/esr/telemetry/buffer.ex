defmodule Esr.Telemetry.Buffer do
  @moduledoc """
  ETS-backed rolling buffer of telemetry events (spec §3.6, PRD 01 F15).
  Retention window configurable in minutes (default 15). Events older
  than the window are evicted by a periodic prune task.

  Multiple named buffers can coexist — the ETS table is named after
  the GenServer's `:name` option so tests can run in isolation.

  Public API:
    start_link(opts) — opts: [:name, :retention_minutes]
    record(name, event, measurements, metadata) — append
    query(name, opts) — opts: [:duration_seconds]
  """

  @behaviour Esr.Role.State

  use GenServer

  defmodule Event do
    @moduledoc false
    defstruct [:ts_unix_ms, :event, :measurements, :metadata]

    @type t :: %__MODULE__{
            ts_unix_ms: integer(),
            event: [atom()],
            measurements: map(),
            metadata: map()
          }
  end

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec record(atom(), [atom()], map(), map()) :: :ok
  def record(name, event, measurements \\ %{}, metadata \\ %{}) do
    now = System.os_time(:millisecond)

    :ets.insert(table_name(name), {
      {now, make_ref()},
      %Event{
        ts_unix_ms: now,
        event: event,
        measurements: measurements,
        metadata: metadata
      }
    })

    :ok
  end

  @spec query(atom(), keyword()) :: [Event.t()]
  def query(name, opts) do
    duration_s = Keyword.get(opts, :duration_seconds, 900)
    floor_ms = System.os_time(:millisecond) - duration_s * 1_000

    :ets.select(table_name(name), [
      {
        {{:"$1", :_}, :"$2"},
        [{:>=, :"$1", floor_ms}],
        [:"$2"]
      }
    ])
  end

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    retention_min = Keyword.get(opts, :retention_minutes, 15)

    table = table_name(name)
    :ets.new(table, [:named_table, :ordered_set, :public, read_concurrency: true])

    schedule_prune(retention_min)

    {:ok, %{table: table, retention_min: retention_min}}
  end

  @impl GenServer
  def handle_info(:prune, %{table: table, retention_min: mins} = state) do
    floor_ms = System.os_time(:millisecond) - mins * 60 * 1_000
    :ets.select_delete(table, [{{{:"$1", :_}, :_}, [{:<, :"$1", floor_ms}], [true]}])
    schedule_prune(mins)
    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # internals
  # ------------------------------------------------------------------

  defp table_name(buffer_name), do: :"esr_telemetry_#{buffer_name}"

  defp schedule_prune(mins) do
    Process.send_after(self(), :prune, mins * 60 * 1_000)
  end
end

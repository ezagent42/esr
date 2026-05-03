defmodule Esr.Resource.DeadLetterQueue do
  @moduledoc """
  Bounded FIFO queue for events that failed to route (spec §5.4 / PRD
  01 F19). Three lands-here cases:

  - unknown target — Route/Emit referenced an actor/adapter that
    doesn't exist
  - handler retry exhausted — HandlerRouter.call failed twice
  - adapter directive failure after retries

  Default capacity 10 000 entries. Oldest-first eviction on overflow.
  `list/1` enumerates current entries; `clear/1` empties.

  Telemetry `[:esr, :deadletter, :event]` fires on every enqueue.
  """
  use GenServer

  defmodule Entry do
    @moduledoc false
    defstruct [:id, :ts_unix_ms, :reason, :target, :msg, :source, :metadata]

    @type t :: %__MODULE__{
            id: String.t(),
            ts_unix_ms: integer(),
            reason: atom(),
            target: String.t() | nil,
            msg: any(),
            source: String.t() | nil,
            metadata: map()
          }
  end

  @default_max_entries 10_000

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Enqueue a dead-letter event. `payload` must include at least a
  `:reason` atom; other keys (`:target`, `:msg`, `:source`,
  `:metadata`) are optional and stored verbatim.
  """
  @spec enqueue(atom(), map()) :: :ok
  def enqueue(name, payload) when is_map(payload) do
    GenServer.cast(name, {:enqueue, payload})
  end

  @spec list(atom()) :: [Entry.t()]
  def list(name), do: GenServer.call(name, :list)

  @spec clear(atom()) :: :ok
  def clear(name), do: GenServer.call(name, :clear)

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       max_entries: Keyword.get(opts, :max_entries, @default_max_entries),
       entries: :queue.new(),
       size: 0
     }}
  end

  @impl GenServer
  def handle_cast({:enqueue, payload}, state) do
    entry = %Entry{
      id: "dl-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)),
      ts_unix_ms: System.os_time(:millisecond),
      reason: Map.get(payload, :reason),
      target: Map.get(payload, :target),
      msg: Map.get(payload, :msg),
      source: Map.get(payload, :source),
      metadata: Map.get(payload, :metadata, %{})
    }

    {queue, size} = push_with_eviction(state.entries, state.size, entry, state.max_entries)

    :telemetry.execute(
      [:esr, :deadletter, :event],
      %{size: size},
      %{reason: entry.reason, target: entry.target, id: entry.id}
    )

    {:noreply, %{state | entries: queue, size: size}}
  end

  @impl GenServer
  def handle_call(:list, _from, state) do
    {:reply, :queue.to_list(state.entries), state}
  end

  @impl GenServer
  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | entries: :queue.new(), size: 0}}
  end

  # ------------------------------------------------------------------
  # internals
  # ------------------------------------------------------------------

  defp push_with_eviction(queue, size, entry, max_entries) do
    if size < max_entries do
      {:queue.in(entry, queue), size + 1}
    else
      {_, queue_after_drop} = :queue.out(queue)
      {:queue.in(entry, queue_after_drop), size}
    end
  end
end

defmodule Esr.Entity.Pool do
  @moduledoc """
  Pool of interchangeable Peer.Stateful workers.

  Default `max_workers: 128` (spec D16). Optional `pools.yaml` can override
  per-pool limits; unspecified pools inherit the default.

  See spec §3.4.
  """
  use GenServer

  @default_max 128

  def default_max_workers, do: @default_max

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def acquire(pool, opts \\ []) do
    timeout = opts[:timeout] || 5000
    # Give the server a small buffer beyond the waiter timeout so the
    # {:error, :pool_exhausted} reply can arrive before the call aborts.
    GenServer.call(pool, {:acquire, opts}, timeout + 1000)
  end
  def release(pool, pid), do: GenServer.cast(pool, {:release, pid})

  @impl true
  def init(opts) do
    max = opts[:max] || @default_max
    worker_mod = Keyword.fetch!(opts, :worker)
    {:ok, %{max: max, worker_mod: worker_mod, workers: %{}, available: :queue.new(), waiters: :queue.new()}}
  end

  @impl true
  def handle_call({:acquire, opts}, from, state) do
    case :queue.out(state.available) do
      {{:value, pid}, q} -> {:reply, {:ok, pid}, %{state | available: q}}
      {:empty, _} ->
        if map_size(state.workers) < state.max do
          {:ok, pid} = state.worker_mod.start_link([])
          workers = Map.put(state.workers, pid, true)
          Process.monitor(pid)
          {:reply, {:ok, pid}, %{state | workers: workers}}
        else
          timeout = opts[:timeout] || 5000
          if timeout == 0 do
            {:reply, {:error, :pool_exhausted}, state}
          else
            Process.send_after(self(), {:waiter_timeout, from}, timeout)
            {:noreply, %{state | waiters: :queue.in({from, :os.system_time(:millisecond) + timeout}, state.waiters)}}
          end
        end
    end
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    case :queue.out(state.waiters) do
      {{:value, {from, _deadline}}, q} ->
        GenServer.reply(from, {:ok, pid})
        {:noreply, %{state | waiters: q}}
      {:empty, _} ->
        {:noreply, %{state | available: :queue.in(pid, state.available)}}
    end
  end

  @impl true
  def handle_info({:waiter_timeout, from}, state) do
    # Reply with exhaustion if still waiting
    new_waiters = :queue.filter(fn {f, _} -> f != from end, state.waiters)
    if :queue.len(new_waiters) < :queue.len(state.waiters) do
      GenServer.reply(from, {:error, :pool_exhausted})
    end
    {:noreply, %{state | waiters: new_waiters}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    workers = Map.delete(state.workers, pid)
    available = :queue.filter(fn p -> p != pid end, state.available)
    {:noreply, %{state | workers: workers, available: available}}
  end
end

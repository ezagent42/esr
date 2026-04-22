defmodule Esr.PeerPoolTest do
  use ExUnit.Case, async: false

  defmodule DummyWorker do
    use GenServer
    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    def init(args), do: {:ok, args}
    def handle_call(:ping, _, s), do: {:reply, :pong, s}
  end

  test "default max_workers is 128" do
    assert Esr.PeerPool.default_max_workers() == 128
  end

  test "acquire returns a worker pid and release puts it back" do
    {:ok, pool} = Esr.PeerPool.start_link(name: :test_pool_1, worker: DummyWorker, max: 4)

    {:ok, w1} = Esr.PeerPool.acquire(pool)
    assert GenServer.call(w1, :ping) == :pong

    :ok = Esr.PeerPool.release(pool, w1)
    # Acquire again, may or may not be same worker
    {:ok, w2} = Esr.PeerPool.acquire(pool)
    assert is_pid(w2)
  end

  test "pool exhaustion returns :pool_exhausted" do
    {:ok, pool} = Esr.PeerPool.start_link(name: :test_pool_2, worker: DummyWorker, max: 2)

    {:ok, _} = Esr.PeerPool.acquire(pool)
    {:ok, _} = Esr.PeerPool.acquire(pool)
    assert {:error, :pool_exhausted} = Esr.PeerPool.acquire(pool, timeout: 100)
  end
end

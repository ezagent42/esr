defmodule Esr.Slash.CleanupRendezvousTest do
  @moduledoc """
  Unit tests for `Esr.Slash.CleanupRendezvous` (PR-2.3a). The module is
  the breakout from `Esr.Admin.Dispatcher`'s cleanup-signal rendezvous;
  these tests cover the same surface that the cleanup-related
  Dispatcher tests covered, scoped to the standalone module.
  """

  use ExUnit.Case, async: false

  alias Esr.Slash.CleanupRendezvous

  setup do
    # The application supervisor starts CleanupRendezvous as part of
    # its child tree, but tests sometimes terminate it (e.g. supervisor
    # restart tests). Make sure it's up before each test in this
    # module.
    if Process.whereis(CleanupRendezvous) == nil do
      start_supervised!(CleanupRendezvous)
    end

    :ok
  end

  test "register + signal forwards {:cleanup_signal, status, details} to the registered Task" do
    sid = "sid-#{System.unique_integer([:positive])}"
    test_pid = self()

    waiter =
      spawn_link(fn ->
        receive do
          msg -> send(test_pid, {:waiter_got, msg})
        end
      end)

    :ok = CleanupRendezvous.register_cleanup(sid, waiter)
    :ok = CleanupRendezvous.signal_cleanup(sid, "CLEANED", %{"foo" => 1})

    assert_receive {:waiter_got, {:cleanup_signal, "CLEANED", %{"foo" => 1}}}, 500
  end

  test "deregister removes the entry; subsequent signal is a no-op-with-warning" do
    sid = "sid-#{System.unique_integer([:positive])}"

    :ok = CleanupRendezvous.register_cleanup(sid, self())
    :ok = CleanupRendezvous.deregister_cleanup(sid)
    :ok = CleanupRendezvous.signal_cleanup(sid, "CLEANED", %{})

    refute_receive {:cleanup_signal, _, _}, 100
  end

  test "signal with no waiter is a no-op-with-warning" do
    sid = "no-waiter-#{System.unique_integer([:positive])}"
    :ok = CleanupRendezvous.signal_cleanup(sid, "CLEANED", %{})
    # Process must still be alive
    assert Process.alive?(Process.whereis(CleanupRendezvous))
  end

  test "signal with dead waiter pid is dropped silently" do
    sid = "dead-#{System.unique_integer([:positive])}"
    {:ok, dead} = Task.start(fn -> :ok end)
    Process.monitor(dead)
    assert_receive {:DOWN, _, :process, ^dead, _}

    :ok = CleanupRendezvous.register_cleanup(sid, dead)
    :ok = CleanupRendezvous.signal_cleanup(sid, "CLEANED", %{})
    # No crash. State should now have removed the entry.
    state = :sys.get_state(CleanupRendezvous)
    refute Map.has_key?(state.pending, sid)
  end

  test "duplicate registration overwrites the previous waiter" do
    sid = "dup-#{System.unique_integer([:positive])}"
    test_pid = self()

    waiter1 =
      spawn_link(fn ->
        receive do
          msg -> send(test_pid, {:w1, msg})
        end
      end)

    waiter2 =
      spawn_link(fn ->
        receive do
          msg -> send(test_pid, {:w2, msg})
        end
      end)

    :ok = CleanupRendezvous.register_cleanup(sid, waiter1)
    :ok = CleanupRendezvous.register_cleanup(sid, waiter2)
    :ok = CleanupRendezvous.signal_cleanup(sid, "CLEANED", %{})

    assert_receive {:w2, {:cleanup_signal, "CLEANED", %{}}}, 500
    refute_receive {:w1, _}, 100
  end
end

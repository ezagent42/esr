defmodule Esr.Admin.SupervisorTest do
  @moduledoc """
  DI-5 Task 10 — Admin subsystem scaffold.

  Asserts that starting `Esr.Admin.Supervisor` brings up both long-lived
  GenServers (Dispatcher + CommandQueue.Watcher). The Application boot
  already starts one instance, so the test tears that down first and
  re-starts under a dedicated ESRD_HOME so the Watcher's mkdir_p runs
  against a disposable tmp dir.
  """
  use ExUnit.Case, async: false

  setup do
    tmp = Path.join(System.tmp_dir!(), "admin_sup_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "default/admin_queue/pending"))
    prev = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    on_exit(fn ->
      if prev, do: System.put_env("ESRD_HOME", prev), else: System.delete_env("ESRD_HOME")
      File.rm_rf!(tmp)
    end)

    :ok
  end

  test "supervision tree starts Dispatcher and Watcher" do
    # Application boot already starts Esr.Admin.Supervisor. If it's
    # alive, stop it through the Application supervisor so the name is
    # fully unregistered before we re-start.
    case Process.whereis(Esr.Admin.Supervisor) do
      nil ->
        :ok

      pid ->
        :ok = Supervisor.terminate_child(Esr.Supervisor, Esr.Admin.Supervisor)
        wait_for_down(pid, 1_000)
    end

    {:ok, _sup} = Esr.Admin.Supervisor.start_link([])
    # Give children a moment to register.
    Process.sleep(100)
    assert Process.whereis(Esr.Admin.Dispatcher) != nil
    assert Process.whereis(Esr.Admin.CommandQueue.Watcher) != nil
  end

  defp wait_for_down(pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      timeout -> :ok
    end
  end
end

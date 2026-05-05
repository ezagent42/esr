defmodule Esr.Slash.SupervisorTest do
  @moduledoc """
  DI-5 Task 10 — Admin subsystem scaffold.

  Asserts that starting `Esr.Slash.Supervisor` brings up the
  long-lived GenServer children (post PR-2.3b-2: CommandQueue.Watcher
  + CommandQueue.Janitor; the legacy Dispatcher was deleted).

  The Application boot already starts one instance, so the test tears
  that down first and re-starts under a dedicated ESRD_HOME so the
  Watcher's mkdir_p runs against a disposable tmp dir.
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

  test "supervision tree starts CommandQueue.Watcher + Janitor" do
    # Application boot already starts Esr.Slash.Supervisor. If it's
    # alive, stop it through the Application supervisor so the name is
    # fully unregistered before we re-start.
    case Process.whereis(Esr.Slash.Supervisor) do
      nil ->
        :ok

      pid ->
        :ok = Supervisor.terminate_child(Esr.Supervisor, Esr.Slash.Supervisor)
        wait_for_down(pid, 1_000)
    end

    {:ok, _sup} = Esr.Slash.Supervisor.start_link([])
    # Give children a moment to register.
    Process.sleep(100)
    assert Process.whereis(Esr.Slash.QueueWatcher) != nil
    assert Process.whereis(Esr.Slash.QueueJanitor) != nil
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

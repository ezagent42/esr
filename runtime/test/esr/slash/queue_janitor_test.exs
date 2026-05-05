defmodule Esr.Slash.QueueJanitorTest do
  @moduledoc """
  DI-7b Task 14c — CommandQueue.Janitor retention sweep.

  `sweep/1` is a pure function (reads `Esr.Paths.admin_queue_dir/0`
  at call time, walks two directories, removes old files), so these
  tests do **not** start a Janitor GenServer. They set `ESRD_HOME`
  to a disposable tmp tree, seed files with `File.touch!/2` at a
  past/recent posix mtime, and drive `sweep/1` directly.
  """
  use ExUnit.Case, async: false

  alias Esr.Slash.QueueJanitor, as: Janitor

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "admin_janitor_#{System.unique_integer([:positive])}"
      )

    completed = Path.join(tmp, "default/admin_queue/completed")
    failed = Path.join(tmp, "default/admin_queue/failed")
    File.mkdir_p!(completed)
    File.mkdir_p!(failed)

    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    on_exit(fn ->
      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, completed: completed, failed: failed}
  end

  test "removes completed files older than retention_days", %{completed: completed} do
    old = Path.join(completed, "old.yaml")
    File.write!(old, "id: old\n")
    File.touch!(old, System.system_time(:second) - 20 * 86_400)

    assert :ok = Janitor.sweep(retention_days: 14)
    refute File.exists?(old)
  end

  test "removes failed files older than retention_days", %{failed: failed} do
    old = Path.join(failed, "old.yaml")
    File.write!(old, "id: old\n")
    File.touch!(old, System.system_time(:second) - 30 * 86_400)

    assert :ok = Janitor.sweep(retention_days: 14)
    refute File.exists?(old)
  end

  test "keeps files newer than retention_days", %{completed: completed} do
    fresh = Path.join(completed, "fresh.yaml")
    File.write!(fresh, "id: fresh\n")
    File.touch!(fresh, System.system_time(:second) - 3 * 86_400)

    assert :ok = Janitor.sweep(retention_days: 14)
    assert File.exists?(fresh)
  end

  test "is a no-op on empty / missing directories", %{tmp: tmp} do
    # Blow away the admin_queue subtree to simulate pre-init state.
    File.rm_rf!(Path.join(tmp, "default/admin_queue"))
    assert :ok = Janitor.sweep(retention_days: 14)
  end
end

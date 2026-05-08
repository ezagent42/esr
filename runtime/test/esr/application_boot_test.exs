defmodule Esr.ApplicationBootTest do
  use ExUnit.Case, async: false

  test "Scope.Admin, Scope.Supervisor, Scope.Router are all booted" do
    # All should already be started by Esr.Application; verify via whereis.
    assert is_pid(Process.whereis(Esr.Scope.Admin))
    assert is_pid(Process.whereis(Esr.Scope.Admin.Process))
    assert is_pid(Process.whereis(Esr.Scope.Supervisor))
    assert is_pid(Process.whereis(Esr.Scope.Registry))
    # PR-8 T4: Scope.Router now boots with the app (was :noproc in
    # production because only tests called start_supervised/1).
    assert is_pid(Process.whereis(Esr.Scope.Router))
  end

  test "child order: Esr.Scope.Registry < Scope.Admin < Scope.Supervisor" do
    # Inspect Esr.Supervisor's child list; assert ordering is correct.
    #
    # Note: Supervisor.which_children/1 returns children in REVERSE start
    # order (most-recently-started first). So a child that started earlier
    # has a LARGER index. Boot-order intent per spec §6 Risk F:
    #   Esr.Scope.Registry (1st) < Esr.Scope.Admin (2nd) < Esr.Scope.Supervisor (3rd)
    # which translates to list indices:
    #   registry_idx > admin_idx > sessions_idx.
    children = Supervisor.which_children(Esr.Supervisor)
    ids = Enum.map(children, fn {id, _, _, _} -> id end)

    registry_idx = Enum.find_index(ids, &(&1 == Esr.Scope.Registry))
    admin_idx = Enum.find_index(ids, &(&1 == Esr.Scope.Admin))
    sessions_idx = Enum.find_index(ids, &(&1 == Esr.Scope.Supervisor))

    assert is_integer(registry_idx)
    assert is_integer(admin_idx)
    assert is_integer(sessions_idx)
    assert registry_idx > admin_idx
    assert admin_idx > sessions_idx
  end
end

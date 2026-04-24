defmodule Esr.ApplicationBootTest do
  use ExUnit.Case, async: false

  test "AdminSession, SessionsSupervisor, SessionRouter are all booted" do
    # All should already be started by Esr.Application; verify via whereis.
    assert is_pid(Process.whereis(Esr.AdminSession))
    assert is_pid(Process.whereis(Esr.AdminSessionProcess))
    assert is_pid(Process.whereis(Esr.SessionsSupervisor))
    assert is_pid(Process.whereis(Esr.Session.Registry))
    # PR-8 T4: SessionRouter now boots with the app (was :noproc in
    # production because only tests called start_supervised/1).
    assert is_pid(Process.whereis(Esr.SessionRouter))
  end

  test "child order: Esr.Session.Registry < AdminSession < SessionsSupervisor" do
    # Inspect Esr.Supervisor's child list; assert ordering is correct.
    #
    # Note: Supervisor.which_children/1 returns children in REVERSE start
    # order (most-recently-started first). So a child that started earlier
    # has a LARGER index. Boot-order intent per spec §6 Risk F:
    #   Esr.Session.Registry (1st) < Esr.AdminSession (2nd) < Esr.SessionsSupervisor (3rd)
    # which translates to list indices:
    #   registry_idx > admin_idx > sessions_idx.
    children = Supervisor.which_children(Esr.Supervisor)
    ids = Enum.map(children, fn {id, _, _, _} -> id end)

    registry_idx = Enum.find_index(ids, &(&1 == Esr.Session.Registry))
    admin_idx = Enum.find_index(ids, &(&1 == Esr.AdminSession))
    sessions_idx = Enum.find_index(ids, &(&1 == Esr.SessionsSupervisor))

    assert is_integer(registry_idx)
    assert is_integer(admin_idx)
    assert is_integer(sessions_idx)
    assert registry_idx > admin_idx
    assert admin_idx > sessions_idx
  end
end

defmodule Esr.ScopeAdminSlashHandlerBootTest do
  @moduledoc """
  PR-8 T1 — SlashHandler must be reachable via
  `Esr.Scope.Admin.Process.slash_handler_ref/0` without any test-side
  `start_supervised/1` step. This test proves the production path works.
  """
  use ExUnit.Case, async: false

  test "Esr.Scope.Admin.Process.slash_handler_ref/0 returns a live pid after app boot" do
    # Don't start_supervised/1 SlashHandler — rely on the normal
    # supervision tree (app was started by test_helper.exs → ExUnit).
    assert {:ok, pid} = Esr.Scope.Admin.Process.slash_handler_ref()
    assert is_pid(pid)
    assert Process.alive?(pid)
  end
end

defmodule SidecarCleanupAtExitTest do
  @moduledoc """
  Regression test for the `System.at_exit/1` hook in `test/test_helper.exs`
  that force-stops orphaned erlexec children on test BEAM exit.

  Why this exists: 2026-05-10 the dev macOS workstation had accumulated
  198 zombie BEAMs (`mix phx.server` + `mix test` runs that never
  terminated cleanly) plus 78 orphan `feishu_adapter_runner` python
  sidecars. Each leaked sidecar = an erlexec exec-port child whose
  parent BEAM was killed by `kill -9` from the operator (or by a hung
  shell). erlexec's `:kill_timeout` only protects against the BEAM
  exiting cleanly — a hard kill of the BEAM disconnects the exec-port
  and the OS child re-parents to init.

  The at_exit hook in test_helper.exs walks `:exec.which_children/0`
  and `stop_and_wait/2`'s every live OS pid before the test BEAM exits,
  closing the leak for the common test-driven path.

  Functional validation of "kill on real BEAM exit" requires spawning a
  separate OS process, which is overkill here. Instead this test asserts:
    1. The hook source is present in test_helper.exs (registered).
    2. The erlexec API the hook depends on hasn't changed shape — i.e.
       `:exec.which_children/0` returns a list (possibly empty) and
       `:exec.stop_and_wait/2` is exported with arity 2.

  If the erlexec library upgrades and changes either of those, this test
  fails BEFORE the leak silently returns in production.
  """

  use ExUnit.Case, async: true

  @test_helper_path Path.expand("test_helper.exs", __DIR__)

  test "test_helper.exs registers a System.at_exit sidecar cleanup hook" do
    helper = File.read!(@test_helper_path)

    assert helper =~ "System.at_exit",
           "expected test_helper.exs to register a System.at_exit hook"

    assert helper =~ ":exec.which_children",
           "expected at_exit hook to walk :exec.which_children/0"

    assert helper =~ ":exec.stop_and_wait",
           "expected at_exit hook to call :exec.stop_and_wait/2 on each child"

    assert helper =~ "Process.whereis(:exec)",
           "expected at_exit hook to guard on :exec being alive"
  end

  test ":exec.which_children/0 returns a list (API shape unchanged)" do
    # If :exec isn't running in this test context, skip — the hook itself
    # has the same Process.whereis guard.
    if Process.whereis(:exec) == nil do
      :ok
    else
      result = :exec.which_children()
      assert is_list(result),
             "erlexec API drift: which_children/0 must return a list; got #{inspect(result)}"

      # If any children are present, every entry must be an integer ospid
      # — the hook iterates them as `for os_pid <- ...`. A 2-tuple shape
      # (some erlexec versions/forks) would silently break the hook.
      Enum.each(result, fn entry ->
        assert is_integer(entry),
               "erlexec API drift: which_children/0 entries must be integer ospids; got #{inspect(entry)}"
      end)
    end
  end

  test ":exec.stop_and_wait/2 is exported (API shape unchanged)" do
    assert function_exported?(:exec, :stop_and_wait, 2),
           "erlexec API drift: :exec.stop_and_wait/2 must be exported"
  end
end

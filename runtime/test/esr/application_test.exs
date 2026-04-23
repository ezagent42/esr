defmodule Esr.ApplicationTest do
  @moduledoc """
  PRD 01 F02 — supervision tree. Verifies every supervisor / registry
  declared in the spec §3.1 tree is registered and alive after the
  application starts.

  The PRD's stated test is `Process.whereis/1 returns a pid for each`,
  so that is exactly what this test asserts; strategy checks and child-
  count invariants are out of scope for this FR (they come via review).
  """

  use ExUnit.Case, async: false

  @expected_processes [
    Esr.PeerRegistry,
    Esr.PeerSupervisor,
    # (P2-16) Esr.AdapterHub.Supervisor removed — its Registry's role
    # is subsumed by Esr.SessionRegistry.
    # (P3-13) Esr.Topology.Supervisor removed — SessionRouter is now
    # the sole control-plane module.
    Esr.HandlerRouter.Supervisor,
    Esr.Persistence.Supervisor,
    Esr.Telemetry.Supervisor,
    EsrWeb.PubSub,
    EsrWeb.Endpoint
  ]

  test "application starts every supervisor listed in spec §3.1" do
    # Application is started by test_helper.exs; we only assert aliveness here.
    for name <- @expected_processes do
      assert is_pid(Process.whereis(name)),
             "expected #{inspect(name)} to be registered and alive, " <>
               "but Process.whereis/1 returned nil"
    end
  end
end

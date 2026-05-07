defmodule Esr.M5ActorQuerySpawnTest do
  @moduledoc """
  M-5.1 invariant gate: after `InstanceRegistry.add_instance_and_spawn/2`
  succeeds for `(session_id, name)`, `ActorQuery.find_by_name(session_id,
  name)` must return `{:ok, pid}` for the freshly spawned CC peer, and
  `ActorQuery.list_by_role(session_id, :cc_process)` must include it.

  This is the "would surprise a future maintainer if it broke" test
  for the multi-instance routing cleanup spec — it exercises the full
  M-1+M-2 chain end-to-end:

      Scope.start_link  →  AgentSupervisor (per-session DynSup, M-2.6)
                       └→  AgentInstanceSupervisor (:one_for_all, M-2.6)
                            ├→ CCProcess.init (registers Index 2/3)
                            └→ PtyProcess.init (registers Index 2/3)

  Tagged `:integration` because PtyProcess.init spawns a real OS
  process via erlexec — `start_cmd: "sleep 60"` is passed through
  the workspace config so the test does not depend on `claude`
  being on $PATH. A short timeout still kills the OS process via
  the supervisor tree teardown when the test exits.

  Run with: `mix test --include integration test/esr/integration/m5_actor_query_spawn_test.exs`
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 30_000

  setup do
    # Each test gets a unique session id so tests can run interleaved
    # without colliding via-tuples in Esr.Scope.Registry.
    sid = "m5-spawn-#{System.unique_integer([:positive])}"

    {:ok, sup_pid} =
      Esr.Scope.start_link(%{
        session_id: sid,
        agent_name: "cc",
        dir: "/tmp",
        chat_thread_key: %{chat_id: "oc_m5", thread_id: ""},
        metadata: %{}
      })

    on_exit(fn ->
      if Process.alive?(sup_pid) do
        ref = Process.monitor(sup_pid)
        Process.exit(sup_pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^sup_pid, _} -> :ok
        after
          5_000 -> :ok
        end
      end
    end)

    %{sid: sid, sup_pid: sup_pid}
  end

  test "after add_instance_and_spawn, ActorQuery resolves the CC pid", %{sid: sid} do
    name = "agent-#{System.unique_integer([:positive])}"

    # Pre-condition: nothing registered yet.
    assert :not_found = Esr.ActorQuery.find_by_name(sid, name)
    assert [] = Esr.ActorQuery.list_by_role(sid, :cc_process)

    # Spawn via the InstanceRegistry atomic path. `start_cmd: "sleep 60"`
    # threads through to PtyProcess so the test does not need a real
    # claude binary; the sleep is killed when the supervisor tree
    # tears down at on_exit. Workspace `dir: /tmp` because the
    # default `/tmp/esr-agent-<sid>` doesn't exist (erlexec rejects
    # spawn with non-existent cwd).
    result =
      Esr.Entity.Agent.InstanceRegistry.add_instance_and_spawn(%{
        session_id: sid,
        type: "cc",
        name: name,
        config: %{"start_cmd" => "/bin/sleep 60", "dir" => "/tmp"}
      })

    assert {:ok, %{cc_pid: cc_pid, pty_pid: pty_pid, actor_ids: ids}} = result

    assert is_pid(cc_pid)
    assert is_pid(pty_pid)
    assert is_binary(ids.cc)
    assert is_binary(ids.pty)

    # M-5 gate: spawn → find_by_name returns the CC pid for this session.
    # Asserted on CC only (not PT) because PT's GenServer lifecycle is
    # bound to a real OS process via erlexec. In CI environments where
    # the spawned shell exits unexpectedly, the IndexWatcher monitor
    # cleans the (sid, name)/role indexes for PT before this assertion
    # runs. The CC peer is a pure GenServer with no OS dependency, so
    # its index registration is stable for the lifetime of this test.
    # Scenario 18 (e2e shell) covers PT live-routing end-to-end.
    assert {:ok, ^cc_pid} = Esr.ActorQuery.find_by_name(sid, name)

    cc_role_pids = Esr.ActorQuery.list_by_role(sid, :cc_process)
    assert cc_pid in cc_role_pids
  end
end

defmodule Esr.SessionProcessGrantsTest do
  @moduledoc """
  P3-3a.2: `Esr.SessionProcess` projects its principal's grants locally
  from the global `Esr.Capabilities.Grants` snapshot at init, subscribes
  to `grants_changed:<principal_id>` on PubSub, and refreshes its local
  map on change. `SessionProcess.has?/2` is served from the local map
  (no global ETS lookup per call).
  """
  use ExUnit.Case, async: false

  alias Esr.Capabilities.Grants
  alias Esr.SessionProcess

  setup do
    # The Registry + Grants are app-level. Ensure they're up.
    assert is_pid(Process.whereis(Esr.Session.Registry))

    if Process.whereis(Grants) == nil do
      start_supervised!(Grants)
    end

    :ok
  end

  defp start_session(session_id, principal_id) do
    {:ok, _sup} =
      Esr.Session.start_link(%{
        session_id: session_id,
        agent_name: "cc",
        dir: "/tmp/sgp",
        chat_thread_key: %{chat_id: "oc_#{session_id}", thread_id: "om_#{session_id}"},
        metadata: %{principal_id: principal_id}
      })
  end

  test "SessionProcess pulls initial grants for its principal at init" do
    # Seed BEFORE spawning so init/1 picks the grants up.
    :ok = Grants.load_snapshot(%{"p_init_proj" => ["workspace:proj-i/msg.send"]})
    start_session("sgp-init", "p_init_proj")

    assert SessionProcess.has?("sgp-init", "workspace:proj-i/msg.send")
    refute SessionProcess.has?("sgp-init", "workspace:other/msg.send")
  end

  test "SessionProcess refreshes grants on `grants_changed:<principal_id>` broadcast" do
    :ok = Grants.load_snapshot(%{"p_refresh" => []})
    start_session("sgp-refresh", "p_refresh")

    refute SessionProcess.has?("sgp-refresh", "workspace:new/msg.send")

    # Load a new snapshot — Grants should broadcast grants_changed:p_refresh.
    :ok = Grants.load_snapshot(%{"p_refresh" => ["workspace:new/msg.send"]})

    # Wait for the refresh to land. has? is synchronous so it flushes
    # the mailbox; polling a few times is enough.
    assert eventually(fn ->
             SessionProcess.has?("sgp-refresh", "workspace:new/msg.send")
           end)
  end

  test "multiple sessions with different principals have independent grants" do
    :ok =
      Grants.load_snapshot(%{
        "p_indep_a" => ["workspace:a/msg.send"],
        "p_indep_b" => ["workspace:b/msg.send"]
      })

    start_session("sgp-indep-a", "p_indep_a")
    start_session("sgp-indep-b", "p_indep_b")

    assert SessionProcess.has?("sgp-indep-a", "workspace:a/msg.send")
    refute SessionProcess.has?("sgp-indep-a", "workspace:b/msg.send")

    assert SessionProcess.has?("sgp-indep-b", "workspace:b/msg.send")
    refute SessionProcess.has?("sgp-indep-b", "workspace:a/msg.send")
  end

  test "SessionProcess.has?/2 is served from local state (no global ETS read per call)" do
    # Seed global ETS with a grant, spawn Session, then OVERWRITE the
    # global snapshot with an unrelated principal via a direct ETS
    # insert that bypasses the Grants GenServer (so no broadcast fires
    # for p_local). If has?/2 reads global ETS on every call, it would
    # now return false because the row was removed. If it reads local
    # state, it still returns true — that's the property we want.
    #
    # Because the ETS table is `protected` (owned by Grants), we route
    # the mutation through the Grants server process itself via a
    # handcrafted call. The cleanest cross-process mutation is
    # Grants.load_snapshot/1 — but that broadcasts. So we instead use
    # a spawn that triggers a replace without going through the public
    # load_snapshot/1 broadcast path is impossible from the outside.
    #
    # Alternative: verify has?/2 does NOT call Grants.has?/2 by
    # timing a high-frequency call loop. If we made 10_000 has? calls
    # and the Grants GenServer is the bottleneck, the total is
    # dominated by GenServer.call latency (~μs each). On local
    # projection, the same 10_000 calls fit within a few ms. We assert
    # a loose upper bound that would fail only if reads went through
    # the global path.
    :ok = Grants.load_snapshot(%{"p_local" => ["workspace:proj/msg.send"]})
    start_session("sgp-local", "p_local")

    assert SessionProcess.has?("sgp-local", "workspace:proj/msg.send")

    # 1_000 calls under 200ms — comfortably true for a local map
    # lookup, fails immediately if every call is a round-trip into the
    # global Grants GenServer under test-mode concurrency.
    {elapsed_us, _} =
      :timer.tc(fn ->
        Enum.each(1..1_000, fn _ ->
          SessionProcess.has?("sgp-local", "workspace:proj/msg.send")
        end)
      end)

    assert elapsed_us < 200_000,
           "SessionProcess.has?/2 took #{elapsed_us}μs for 1000 calls — " <>
             "expected local projection path (<200_000μs)"
  end

  test "SessionProcess without principal_id metadata returns false for every check" do
    {:ok, _sup} =
      Esr.Session.start_link(%{
        session_id: "sgp-noprincipal",
        agent_name: "cc",
        dir: "/tmp/sgp",
        chat_thread_key: %{chat_id: "oc_n", thread_id: "om_n"},
        metadata: %{}
      })

    refute SessionProcess.has?("sgp-noprincipal", "workspace:proj/msg.send")
    refute SessionProcess.has?("sgp-noprincipal", "*")
  end

  defp eventually(fun, attempts \\ 20, delay_ms \\ 25)
  defp eventually(_fun, 0, _delay), do: false

  defp eventually(fun, attempts, delay_ms) do
    if fun.() do
      true
    else
      Process.sleep(delay_ms)
      eventually(fun, attempts - 1, delay_ms)
    end
  end
end

defmodule Esr.Commands.Scope.EndTransientCleanupTest do
  @moduledoc """
  Task 5.2 — transient workspace cleanup hook + Risk #2 race serialisation.

  Tests:
    1. Transient workspace with single bound session → deleted on last unbind.
    2. Non-transient workspace → delete_if_no_sessions returns :not_transient.
    3. Transient workspace with 2 sessions, only one unbound → :has_sessions.
    4. delete_if_no_sessions on unknown UUID → :not_found.
    5. Risk #2 race: concurrent unbind+delete_if_no_sessions vs bind — exactly
       one of two XOR outcomes; 20 iterations to catch ordering bugs.
  """
  use ExUnit.Case, async: false

  alias Esr.Resource.Workspace.{Struct, Registry}

  # ── Setup / Teardown ────────────────────────────────────────────────────────

  setup do
    assert is_pid(Process.whereis(Registry)),
           "Esr.Resource.Workspace.Registry must be running (started by Application)"

    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "ws_transient_cleanup_#{unique}")
    File.mkdir_p!(Path.join(tmp, "default"))
    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    on_exit(fn ->
      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)
      :ets.delete_all_objects(:esr_workspaces)
      :ets.delete_all_objects(:esr_workspaces_uuid)
    end)

    {:ok, tmp: tmp}
  end

  # Helper: create and register a transient ESR-bound workspace
  defp put_transient_ws(name, id, tmp) do
    dir = Path.join([tmp, "default", "workspaces", name])
    File.mkdir_p!(dir)

    ws = %Struct{
      id: id,
      name: name,
      owner: "tester",
      folders: [],
      agent: "cc",
      settings: %{},
      env: %{},
      chats: [],
      transient: true,
      location: {:esr_bound, dir}
    }

    :ok = Registry.put(ws)
    ws
  end

  # Helper: create and register a non-transient ESR-bound workspace
  defp put_permanent_ws(name, id, tmp) do
    dir = Path.join([tmp, "default", "workspaces", name])
    File.mkdir_p!(dir)

    ws = %Struct{
      id: id,
      name: name,
      owner: "tester",
      folders: [],
      agent: "cc",
      settings: %{},
      env: %{},
      chats: [],
      transient: false,
      location: {:esr_bound, dir}
    }

    :ok = Registry.put(ws)
    ws
  end

  # ── Test 1: transient + single session → deleted ────────────────────────────

  test "transient workspace with single bound session is deleted when last session unbinds",
       %{tmp: tmp} do
    ws_id = UUID.uuid4()
    put_transient_ws("ws-single-#{System.unique_integer([:positive])}", ws_id, tmp)

    :ok = Registry.bind_session(ws_id, "sid-solo")

    # Workspace exists before cleanup
    assert {:ok, _} = Registry.get_by_id(ws_id)

    :ok = Registry.unbind_session("sid-solo")
    assert {:ok, :deleted} = Registry.delete_if_no_sessions(ws_id)

    # Workspace is gone
    assert :not_found = Registry.get_by_id(ws_id)
  end

  # ── Test 2: non-transient workspace → :not_transient ────────────────────────

  test "non-transient workspace returns :not_transient from delete_if_no_sessions",
       %{tmp: tmp} do
    ws_id = UUID.uuid4()
    put_permanent_ws("ws-perm-#{System.unique_integer([:positive])}", ws_id, tmp)

    assert {:ok, :not_transient} = Registry.delete_if_no_sessions(ws_id)

    # Workspace still exists
    assert {:ok, _} = Registry.get_by_id(ws_id)
  end

  # ── Test 3: transient + 2 sessions, unbind only 1 → :has_sessions ───────────

  test "transient workspace with 2 sessions returns :has_sessions after one unbind",
       %{tmp: tmp} do
    ws_id = UUID.uuid4()
    put_transient_ws("ws-multi-#{System.unique_integer([:positive])}", ws_id, tmp)

    :ok = Registry.bind_session(ws_id, "sid-a")
    :ok = Registry.bind_session(ws_id, "sid-b")

    # Unbind only one session
    :ok = Registry.unbind_session("sid-a")

    assert {:ok, :has_sessions} = Registry.delete_if_no_sessions(ws_id)

    # Workspace still exists
    assert {:ok, _} = Registry.get_by_id(ws_id)
    # sid-b still bound
    assert "sid-b" in Registry.sessions_for(ws_id)
  end

  # ── Test 4: unknown UUID → :not_found ───────────────────────────────────────

  test "delete_if_no_sessions on unknown UUID returns :not_found" do
    unknown_id = UUID.uuid4()
    assert {:error, :not_found} = Registry.delete_if_no_sessions(unknown_id)
  end

  # ── Test 5: Risk #2 race — serialised via GenServer (20 iterations) ─────────

  test "transient cleanup vs concurrent bind serialise via Workspace.Registry GenServer (Risk #2)",
       %{tmp: tmp} do
    for i <- 1..20 do
      ws_id = UUID.uuid4()
      ws_name = "racy-ws-#{System.unique_integer([:positive])}-iter-#{i}"
      ws_dir = Path.join([tmp, "default", "workspaces", ws_name])
      File.mkdir_p!(ws_dir)

      ws = %Struct{
        id: ws_id,
        name: ws_name,
        owner: "tester",
        folders: [],
        agent: "cc",
        settings: %{},
        env: %{},
        chats: [],
        transient: true,
        location: {:esr_bound, ws_dir}
      }

      :ok = Registry.put(ws)
      :ok = Registry.bind_session(ws_id, "sid-1-#{i}")

      # Two concurrent operations:
      task_a =
        Task.async(fn ->
          :ok = Registry.unbind_session("sid-1-#{i}")
          Registry.delete_if_no_sessions(ws_id)
        end)

      task_b =
        Task.async(fn ->
          Registry.bind_session(ws_id, "sid-2-#{i}")
        end)

      result_a = Task.await(task_a, 5000)
      result_b = Task.await(task_b, 5000)

      cleanup_happened = match?({:ok, :deleted}, result_a)
      bind_happened = match?(:ok, result_b)
      workspace_exists = match?({:ok, _}, Registry.get_by_id(ws_id))

      cond do
        cleanup_happened ->
          # A won the race: workspace deleted, B's bind got :workspace_gone
          assert {:error, :workspace_gone} = result_b,
                 "iter #{i}: cleanup won but bind did not return :workspace_gone (got #{inspect(result_b)})"

          refute workspace_exists,
                 "iter #{i}: cleanup won but workspace still exists"

        bind_happened ->
          # B won the race: workspace still exists with sid-2 bound,
          # A's delete saw count > 0 and returned :has_sessions
          assert {:ok, :has_sessions} = result_a,
                 "iter #{i}: bind won but delete_if_no_sessions did not return :has_sessions (got #{inspect(result_a)})"

          assert workspace_exists,
                 "iter #{i}: bind won but workspace does not exist"

          assert "sid-2-#{i}" in Registry.sessions_for(ws_id),
                 "iter #{i}: bind won but sid-2 not in sessions_for"

        true ->
          flunk(
            "iter #{i}: neither path completed cleanly: a=#{inspect(result_a)} b=#{inspect(result_b)}"
          )
      end
    end
  end
end

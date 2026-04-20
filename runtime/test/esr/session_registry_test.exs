defmodule Esr.SessionRegistryTest do
  use ExUnit.Case, async: false

  alias Esr.SessionRegistry

  setup do
    # Registry is started by the Application supervisor; each test can
    # read/write freely since we key by unique session_id per test.
    %{session_id: "sess-#{System.unique_integer([:positive])}"}
  end

  test "register creates an online row", %{session_id: sid} do
    :ok = SessionRegistry.register(sid,
            ws_pid: self(),
            chat_ids: ["oc_x"],
            app_ids: ["cli_x"],
            workspace: "esr-dev")

    {:ok, row} = SessionRegistry.lookup(sid)
    assert row.status == :online
    assert row.workspace == "esr-dev"
    assert row.ws_pid == self()
    # Reviewer S1: peer_pid intentionally omitted from registry row
    refute Map.has_key?(row, :peer_pid)
  end

  test "register with same session_id + different ws_pid evicts old", %{session_id: sid} do
    old_ws = spawn(fn -> receive do _ -> :ok end end)
    new_ws = spawn(fn -> receive do _ -> :ok end end)

    :ok = SessionRegistry.register(sid, ws_pid: old_ws,
            chat_ids: [], app_ids: [], workspace: "w")
    :ok = SessionRegistry.register(sid, ws_pid: new_ws,
            chat_ids: [], app_ids: [], workspace: "w")

    {:ok, row} = SessionRegistry.lookup(sid)
    assert row.ws_pid == new_ws
  end

  test "same ws_pid register is idempotent (no eviction)", %{session_id: sid} do
    ws = spawn(fn -> receive do _ -> :ok end end)
    :ok = SessionRegistry.register(sid, ws_pid: ws,
            chat_ids: [], app_ids: [], workspace: "w1")
    :ok = SessionRegistry.register(sid, ws_pid: ws,
            chat_ids: [], app_ids: [], workspace: "w2")

    {:ok, row} = SessionRegistry.lookup(sid)
    assert row.workspace == "w2"
  end
end

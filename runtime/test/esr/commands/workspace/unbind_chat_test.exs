defmodule Esr.Commands.Workspace.UnbindChatTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Workspace.UnbindChat, as: WorkspaceUnbindChat
  alias Esr.Resource.Workspace.{Struct, Registry}

  # ── Setup / Teardown ──────────────────────────────────────────────────────────

  setup do
    assert is_pid(Process.whereis(Registry))

    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "ws_unbind_chat_test_#{unique}")
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

  # Helper: put an ESR-bound workspace with a given chats list
  defp put_esr_ws(name, id, tmp, chats) do
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
      chats: chats,
      transient: false,
      location: {:esr_bound, dir}
    }

    Registry.put(ws)
    ws
  end

  # ── Test 1: unbind one chat by (chat_id, app_id) → removed ───────────────────

  test "workspace with one chat, unbind by (chat_id, app_id) → ok, action=removed, chats empty",
       %{tmp: tmp} do
    id = "cccccccc-0001-4000-8000-000000000001"
    chats = [%{chat_id: "oc_abc", app_id: "cli_one", kind: "dm"}]
    put_esr_ws("ws-unbind-1", id, tmp, chats)

    assert {:ok, result} =
             WorkspaceUnbindChat.execute(%{
               "args" => %{
                 "name" => "ws-unbind-1",
                 "chat_id" => "oc_abc",
                 "app_id" => "cli_one"
               }
             })

    assert result["name"] == "ws-unbind-1"
    assert result["id"] == id
    assert result["action"] == "removed"
    assert result["removed_count"] == 1
    assert result["chats"] == []

    assert {:ok, updated} = Registry.get_by_id(id)
    assert updated.chats == []
  end

  # ── Test 2: multiple chats, unbind one by chat_id only ───────────────────────

  test "workspace with multiple chats, unbind one by chat_id only → ok, removes match",
       %{tmp: tmp} do
    id = "cccccccc-0002-4000-8000-000000000002"

    chats = [
      %{chat_id: "oc_target", app_id: "cli_a", kind: "dm"},
      %{chat_id: "oc_other", app_id: "cli_b", kind: "dm"}
    ]

    put_esr_ws("ws-unbind-2", id, tmp, chats)

    assert {:ok, result} =
             WorkspaceUnbindChat.execute(%{
               "args" => %{
                 "name" => "ws-unbind-2",
                 "chat_id" => "oc_target"
               }
             })

    assert result["action"] == "removed"
    assert result["removed_count"] == 1
    assert length(result["chats"]) == 1
    [remaining] = result["chats"]
    assert remaining["chat_id"] == "oc_other"

    assert {:ok, updated} = Registry.get_by_id(id)
    assert length(updated.chats) == 1
  end

  # ── Test 3: chat not present → chat_not_bound error ──────────────────────────

  test "unbind chat not present → chat_not_bound error", %{tmp: tmp} do
    id = "cccccccc-0003-4000-8000-000000000003"
    chats = [%{chat_id: "oc_other", app_id: "cli_o", kind: "dm"}]
    put_esr_ws("ws-unbind-3", id, tmp, chats)

    assert {:error, err} =
             WorkspaceUnbindChat.execute(%{
               "args" => %{
                 "name" => "ws-unbind-3",
                 "chat_id" => "oc_nothere"
               }
             })

    assert err["type"] == "chat_not_bound"
    assert err["chat_id"] == "oc_nothere"
    assert err["name"] == "ws-unbind-3"
  end

  # ── Test 4: same chat_id different app_id, unbind with both args → only matching removed ──

  test "multiple chats with same chat_id different app_id; unbind with both args → only matching removed",
       %{tmp: tmp} do
    id = "cccccccc-0004-4000-8000-000000000004"

    chats = [
      %{chat_id: "oc_shared", app_id: "cli_x", kind: "dm"},
      %{chat_id: "oc_shared", app_id: "cli_y", kind: "dm"}
    ]

    put_esr_ws("ws-unbind-4", id, tmp, chats)

    assert {:ok, result} =
             WorkspaceUnbindChat.execute(%{
               "args" => %{
                 "name" => "ws-unbind-4",
                 "chat_id" => "oc_shared",
                 "app_id" => "cli_x"
               }
             })

    assert result["action"] == "removed"
    assert result["removed_count"] == 1
    assert length(result["chats"]) == 1
    [remaining] = result["chats"]
    assert remaining["chat_id"] == "oc_shared"
    assert remaining["app_id"] == "cli_y"

    assert {:ok, updated} = Registry.get_by_id(id)
    assert length(updated.chats) == 1
    [saved] = updated.chats
    assert saved.app_id == "cli_y"
  end

  # ── Test 5: same chat_id different app_id, unbind chat_id only → BOTH removed ─

  test "multiple chats with same chat_id different app_id; unbind with chat_id only → both removed",
       %{tmp: tmp} do
    id = "cccccccc-0005-4000-8000-000000000005"

    chats = [
      %{chat_id: "oc_shared2", app_id: "cli_p", kind: "dm"},
      %{chat_id: "oc_shared2", app_id: "cli_q", kind: "dm"}
    ]

    put_esr_ws("ws-unbind-5", id, tmp, chats)

    assert {:ok, result} =
             WorkspaceUnbindChat.execute(%{
               "args" => %{
                 "name" => "ws-unbind-5",
                 "chat_id" => "oc_shared2"
               }
             })

    assert result["action"] == "removed"
    assert result["removed_count"] == 2
    assert result["chats"] == []

    assert {:ok, updated} = Registry.get_by_id(id)
    assert updated.chats == []
  end

  # ── Test 6: unknown workspace → unknown_workspace ─────────────────────────────

  test "unknown workspace → unknown_workspace error" do
    assert {:error, err} =
             WorkspaceUnbindChat.execute(%{
               "args" => %{
                 "name" => "no-such-ws",
                 "chat_id" => "oc_x"
               }
             })

    assert err["type"] == "unknown_workspace"
    assert err["name"] == "no-such-ws"
  end

  # ── Test 7: missing chat_id → invalid_args ────────────────────────────────────

  test "missing chat_id → invalid_args error" do
    assert {:error, err} =
             WorkspaceUnbindChat.execute(%{
               "args" => %{
                 "name" => "ws-any"
               }
             })

    assert err["type"] == "invalid_args"
  end
end

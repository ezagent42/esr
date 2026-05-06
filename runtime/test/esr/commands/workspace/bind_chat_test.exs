defmodule Esr.Commands.Workspace.BindChatTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Workspace.BindChat, as: WorkspaceBindChat
  alias Esr.Resource.Workspace.{Struct, Registry}

  # ── Setup / Teardown ──────────────────────────────────────────────────────────

  setup do
    assert is_pid(Process.whereis(Registry))

    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "ws_bind_chat_test_#{unique}")
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
  defp put_esr_ws(name, id, tmp, chats \\ []) do
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

  # ── Test 1: no existing chats, valid args → added ─────────────────────────────

  test "ESR-bound workspace with no chats, valid args → ok, action=added, chat persisted",
       %{tmp: tmp} do
    id = "bbbbbbbb-0001-4000-8000-000000000001"
    put_esr_ws("ws-bind-1", id, tmp)

    assert {:ok, result} =
             WorkspaceBindChat.execute(%{
               "args" => %{
                 "name" => "ws-bind-1",
                 "chat_id" => "oc_aaa111",
                 "app_id" => "cli_xxx"
               }
             })

    assert result["name"] == "ws-bind-1"
    assert result["id"] == id
    assert result["action"] == "added"
    assert length(result["chats"]) == 1
    [chat] = result["chats"]
    assert chat["chat_id"] == "oc_aaa111"
    assert chat["app_id"] == "cli_xxx"
    assert chat["kind"] == "dm"

    # Verify persisted
    assert {:ok, updated} = Registry.get_by_id(id)
    assert length(updated.chats) == 1
    [saved] = updated.chats
    assert saved.chat_id == "oc_aaa111"
    assert saved.app_id == "cli_xxx"
    assert saved.kind == "dm"
  end

  # ── Test 2: workspace already has a different chat → both present ─────────────

  test "workspace already has a different chat → both chats present after bind",
       %{tmp: tmp} do
    id = "bbbbbbbb-0002-4000-8000-000000000002"
    existing = [%{chat_id: "oc_existing", app_id: "cli_old", kind: "dm"}]
    put_esr_ws("ws-bind-2", id, tmp, existing)

    assert {:ok, result} =
             WorkspaceBindChat.execute(%{
               "args" => %{
                 "name" => "ws-bind-2",
                 "chat_id" => "oc_new",
                 "app_id" => "cli_new"
               }
             })

    assert result["action"] == "added"
    assert length(result["chats"]) == 2

    chat_ids = Enum.map(result["chats"], & &1["chat_id"])
    assert "oc_existing" in chat_ids
    assert "oc_new" in chat_ids

    assert {:ok, updated} = Registry.get_by_id(id)
    assert length(updated.chats) == 2
  end

  # ── Test 3: duplicate (chat_id+app_id) → already_bound, no write ─────────────

  test "duplicate (same chat_id+app_id) → ok, action=already_bound, chats unchanged",
       %{tmp: tmp} do
    id = "bbbbbbbb-0003-4000-8000-000000000003"
    existing = [%{chat_id: "oc_dup", app_id: "cli_dup", kind: "dm"}]
    put_esr_ws("ws-bind-3", id, tmp, existing)

    assert {:ok, result} =
             WorkspaceBindChat.execute(%{
               "args" => %{
                 "name" => "ws-bind-3",
                 "chat_id" => "oc_dup",
                 "app_id" => "cli_dup"
               }
             })

    assert result["action"] == "already_bound"
    assert length(result["chats"]) == 1

    # Verify NOT written again (still just 1 chat)
    assert {:ok, updated} = Registry.get_by_id(id)
    assert length(updated.chats) == 1
  end

  # ── Test 4: custom kind ("group") → kind preserved ────────────────────────────

  test "custom kind 'group' → kind preserved in stored chat", %{tmp: tmp} do
    id = "bbbbbbbb-0004-4000-8000-000000000004"
    put_esr_ws("ws-bind-4", id, tmp)

    assert {:ok, result} =
             WorkspaceBindChat.execute(%{
               "args" => %{
                 "name" => "ws-bind-4",
                 "chat_id" => "oc_grp",
                 "app_id" => "cli_grp",
                 "kind" => "group"
               }
             })

    assert result["action"] == "added"
    [chat] = result["chats"]
    assert chat["kind"] == "group"

    assert {:ok, updated} = Registry.get_by_id(id)
    [saved] = updated.chats
    assert saved.kind == "group"
  end

  # ── Test 5: omitted kind → defaults to "dm" ───────────────────────────────────

  test "omitted kind → defaults to 'dm'", %{tmp: tmp} do
    id = "bbbbbbbb-0005-4000-8000-000000000005"
    put_esr_ws("ws-bind-5", id, tmp)

    assert {:ok, result} =
             WorkspaceBindChat.execute(%{
               "args" => %{
                 "name" => "ws-bind-5",
                 "chat_id" => "oc_nodm",
                 "app_id" => "cli_nodm"
               }
             })

    [chat] = result["chats"]
    assert chat["kind"] == "dm"
  end

  # ── Test 6: missing app_id → missing_app_id error ─────────────────────────────

  test "missing app_id → missing_app_id error", %{tmp: tmp} do
    id = "bbbbbbbb-0006-4000-8000-000000000006"
    put_esr_ws("ws-bind-6", id, tmp)

    assert {:error, err} =
             WorkspaceBindChat.execute(%{
               "args" => %{
                 "name" => "ws-bind-6",
                 "chat_id" => "oc_noapps"
               }
             })

    assert err["type"] == "missing_app_id"
  end

  # ── Test 7: unknown workspace → unknown_workspace ─────────────────────────────

  test "unknown workspace → unknown_workspace error" do
    assert {:error, err} =
             WorkspaceBindChat.execute(%{
               "args" => %{
                 "name" => "no-such-ws",
                 "chat_id" => "oc_x",
                 "app_id" => "cli_x"
               }
             })

    assert err["type"] == "unknown_workspace"
    assert err["name"] == "no-such-ws"
  end

  # ── Test 8: missing chat_id → invalid_args ────────────────────────────────────

  test "missing chat_id → invalid_args error" do
    assert {:error, err} =
             WorkspaceBindChat.execute(%{
               "args" => %{
                 "name" => "ws-any"
               }
             })

    assert err["type"] == "invalid_args"
  end
end

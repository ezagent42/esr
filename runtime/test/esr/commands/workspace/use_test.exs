defmodule Esr.Commands.Workspace.UseTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Workspace.Use, as: WorkspaceUse
  alias Esr.Resource.Workspace.{Struct, Registry}
  alias Esr.Resource.ChatScope.Registry, as: ChatScopeRegistry

  # ── Setup / Teardown ──────────────────────────────────────────────────────────

  setup do
    assert is_pid(Process.whereis(Registry))
    assert is_pid(Process.whereis(ChatScopeRegistry))

    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "ws_use_test_#{unique}")
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
      # NOTE: :esr_chat_scope_default_workspace_index is :protected (owned by
      # ChatScope.Registry GenServer); cleanup via registry API or unique keys.
    end)

    {:ok, tmp: tmp}
  end

  # Helper: insert a workspace struct directly into the registry
  defp put_ws(name, id, tmp) do
    dir = Path.join([tmp, "default", "workspaces", name])
    File.mkdir_p!(dir)

    ws = %Struct{
      id: id,
      name: name,
      owner: "linyilun",
      folders: [],
      agent: "cc",
      settings: %{},
      env: %{},
      chats: [],
      transient: false,
      location: {:esr_bound, dir}
    }

    Registry.put(ws)
    ws
  end

  # ── Tests ─────────────────────────────────────────────────────────────────────

  # Test 1: happy path — sets default workspace and confirms via get_default_workspace/2
  test "happy path: /workspace use name=esr-dev sets default workspace for chat slot", %{tmp: tmp} do
    id = UUID.uuid4()
    put_ws("esr-dev", id, tmp)

    assert {:ok, result} =
             WorkspaceUse.execute(%{
               "args" => %{"name" => "esr-dev", "chat_id" => "oc_a", "app_id" => "cli_x"}
             })

    assert result["name"] == "esr-dev"
    assert result["id"] == id
    assert result["chat_id"] == "oc_a"
    assert result["app_id"] == "cli_x"
    assert result["action"] == "default_workspace_set"

    assert {:ok, ^id} = ChatScopeRegistry.get_default_workspace("oc_a", "cli_x")
  end

  # Test 2: overwrite — setting a different workspace for the same chat replaces the mapping
  test "setting a different workspace for the same chat overwrites the previous mapping", %{tmp: tmp} do
    id1 = UUID.uuid4()
    id2 = UUID.uuid4()
    put_ws("ws-first", id1, tmp)
    put_ws("ws-second", id2, tmp)

    assert {:ok, _} =
             WorkspaceUse.execute(%{
               "args" => %{"name" => "ws-first", "chat_id" => "oc_b", "app_id" => "cli_y"}
             })

    assert {:ok, ^id1} = ChatScopeRegistry.get_default_workspace("oc_b", "cli_y")

    assert {:ok, _} =
             WorkspaceUse.execute(%{
               "args" => %{"name" => "ws-second", "chat_id" => "oc_b", "app_id" => "cli_y"}
             })

    assert {:ok, ^id2} = ChatScopeRegistry.get_default_workspace("oc_b", "cli_y")
  end

  # Test 3: different chats are independent — each slot gets its own mapping
  test "different chat slots maintain independent default workspace mappings", %{tmp: tmp} do
    id1 = UUID.uuid4()
    id2 = UUID.uuid4()
    put_ws("ws-chat-a", id1, tmp)
    put_ws("ws-chat-b", id2, tmp)

    assert {:ok, _} =
             WorkspaceUse.execute(%{
               "args" => %{"name" => "ws-chat-a", "chat_id" => "oc_chat_a", "app_id" => "cli_z"}
             })

    assert {:ok, _} =
             WorkspaceUse.execute(%{
               "args" => %{"name" => "ws-chat-b", "chat_id" => "oc_chat_b", "app_id" => "cli_z"}
             })

    assert {:ok, ^id1} = ChatScopeRegistry.get_default_workspace("oc_chat_a", "cli_z")
    assert {:ok, ^id2} = ChatScopeRegistry.get_default_workspace("oc_chat_b", "cli_z")
  end

  # Test 4: unknown workspace → unknown_workspace error
  test "unknown workspace name → unknown_workspace error" do
    assert {:error, err} =
             WorkspaceUse.execute(%{
               "args" => %{
                 "name" => "nonexistent-ws",
                 "chat_id" => "oc_x",
                 "app_id" => "cli_x"
               }
             })

    assert err["type"] == "unknown_workspace"
    assert err["name"] == "nonexistent-ws"
  end

  # Test 5: name present but no chat context (CLI invocation) → missing_chat_context
  test "name present but missing chat_id/app_id (CLI) → missing_chat_context error" do
    assert {:error, err} =
             WorkspaceUse.execute(%{
               "args" => %{"name" => "some-ws"}
             })

    assert err["type"] == "missing_chat_context"
    assert err["message"] =~ "chat_id"
  end

  # Test 6: missing args entirely → invalid_args
  test "missing args entirely → invalid_args error" do
    assert {:error, err} = WorkspaceUse.execute(%{})
    assert err["type"] == "invalid_args"
  end
end

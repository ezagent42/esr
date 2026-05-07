defmodule Esr.Commands.Workspace.RenameTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Workspace.Rename, as: WorkspaceRename
  alias Esr.Resource.Workspace.{Struct, Registry}

  # ── Setup / Teardown ──────────────────────────────────────────────────────────

  setup do
    assert is_pid(Process.whereis(Registry))

    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "ws_rename_test_#{unique}")
    File.mkdir_p!(Path.join(tmp, "default"))
    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    on_exit(fn ->
      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)
      Esr.Test.WorkspaceFixture.reset!()
      Esr.Test.WorkspaceFixture.reset!()
      Esr.Resource.Workspace.Bootstrap.run()
      :ets.delete_all_objects(:esr_workspace_name_index_name_to_id)
      :ets.delete_all_objects(:esr_workspace_name_index_id_to_name)
    end)

    {:ok, tmp: tmp}
  end

  # Helper: put a fresh ESR-bound workspace for tests that need one
  defp put_esr_ws(name, id, tmp) do
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

  # Helper: put a fresh repo-bound workspace for tests that need one
  defp put_repo_ws(name, id, repo_path) do
    ws = %Struct{
      id: id,
      name: name,
      owner: "linyilun",
      folders: [%{path: repo_path, name: Path.basename(repo_path)}],
      agent: "cc",
      settings: %{},
      env: %{},
      chats: [],
      transient: false,
      location: {:repo_bound, repo_path}
    }

    Registry.put(ws)
    ws
  end

  # ── Test 1: ESR-bound rename happy path → ok, returns %{"old_name", "new_name", "id" => uuid} ──

  test "ESR-bound rename happy path → ok, returns expected fields", %{tmp: tmp} do
    id = UUID.uuid4()
    put_esr_ws("old-name", id, tmp)

    assert {:ok, result} =
             WorkspaceRename.execute(%{
               "args" => %{"name" => "old-name", "new_name" => "new-name"}
             })

    assert result["old_name"] == "old-name"
    assert result["new_name"] == "new-name"
    assert result["id"] == id

    # Verify persisted: lookup by ID should return new name
    assert {:ok, updated} = Registry.get_by_id(id)
    assert updated.name == "new-name"
  end

  # ── Test 2: ESR-bound rename also renames on-disk directory ──

  test "ESR-bound rename moves the on-disk directory", %{tmp: tmp} do
    id = UUID.uuid4()
    put_esr_ws("dir-old", id, tmp)

    old_dir = Path.join([tmp, "default", "workspaces", "dir-old"])
    new_dir = Path.join([tmp, "default", "workspaces", "dir-new"])

    assert File.exists?(old_dir)
    refute File.exists?(new_dir)

    assert {:ok, _} =
             WorkspaceRename.execute(%{
               "args" => %{"name" => "dir-old", "new_name" => "dir-new"}
             })

    refute File.exists?(old_dir)
    assert File.exists?(new_dir)
    assert File.exists?(Path.join(new_dir, "workspace.json"))
  end

  # ── Test 3: Repo-bound rename: only updates ETS + workspace.json, no directory move ──

  test "repo-bound rename: updates ETS and workspace.json, no directory move", %{tmp: tmp} do
    id = UUID.uuid4()
    repo_path = Path.join(tmp, "fake-repo")
    File.mkdir_p!(repo_path)

    put_repo_ws("repo-old", id, repo_path)

    # workspace.json should be at <repo_path>/.esr/workspace.json
    esr_dir = Path.join(repo_path, ".esr")
    ws_json = Path.join(esr_dir, "workspace.json")

    assert File.exists?(ws_json)

    assert {:ok, _} =
             WorkspaceRename.execute(%{
               "args" => %{"name" => "repo-old", "new_name" => "repo-new"}
             })

    # Directory should NOT move
    assert File.exists?(repo_path)

    # workspace.json should still exist at original path with new name
    assert File.exists?(ws_json)

    # Verify updated struct has new name
    assert {:ok, updated} = Registry.get_by_id(id)
    assert updated.name == "repo-new"
  end

  # ── Test 4: Same name (name == new_name) → same_name error ──

  test "same name → same_name error", %{tmp: tmp} do
    id = UUID.uuid4()
    put_esr_ws("same-ws", id, tmp)

    assert {:error, err} =
             WorkspaceRename.execute(%{
               "args" => %{"name" => "same-ws", "new_name" => "same-ws"}
             })

    assert err["type"] == "same_name"
    assert err["message"] =~ "must differ"
  end

  # ── Test 5: New name with invalid characters → invalid_name error ──

  test "new name with invalid characters → invalid_name error", %{tmp: tmp} do
    id = UUID.uuid4()
    put_esr_ws("valid-old", id, tmp)

    assert {:error, err} =
             WorkspaceRename.execute(%{
               "args" => %{"name" => "valid-old", "new_name" => "has space"}
             })

    assert err["type"] == "invalid_name"
  end

  # ── Test 6: New name conflicts with existing workspace → rename_failed error ──

  test "new name conflicts with existing workspace → rename_failed", %{tmp: tmp} do
    id1 = UUID.uuid4()
    id2 = UUID.uuid4()

    put_esr_ws("ws-one", id1, tmp)
    put_esr_ws("ws-two", id2, tmp)

    # Try to rename ws-one to ws-two (which already exists)
    assert {:error, err} =
             WorkspaceRename.execute(%{
               "args" => %{"name" => "ws-one", "new_name" => "ws-two"}
             })

    assert err["type"] == "rename_failed"
    assert err["detail"] =~ "name_exists"
  end

  # ── Test 7: Old name unknown → unknown_workspace error ──

  test "old name unknown → unknown_workspace error" do
    assert {:error, err} =
             WorkspaceRename.execute(%{
               "args" => %{"name" => "nonexistent", "new_name" => "new-name"}
             })

    assert err["type"] == "unknown_workspace"
    assert err["name"] == "nonexistent"
  end

  # ── Test 8: Missing args → invalid_args error ──

  test "missing args → invalid_args error" do
    assert {:error, err} = WorkspaceRename.execute(%{})
    assert err["type"] == "invalid_args"
  end

  test "missing name → invalid_args" do
    assert {:error, err} =
             WorkspaceRename.execute(%{
               "args" => %{"new_name" => "some-name"}
             })

    assert err["type"] == "invalid_args"
  end

  test "missing new_name → invalid_args" do
    assert {:error, err} =
             WorkspaceRename.execute(%{
               "args" => %{"name" => "some-name"}
             })

    assert err["type"] == "invalid_args"
  end

  test "empty name → invalid_args" do
    assert {:error, err} =
             WorkspaceRename.execute(%{
               "args" => %{"name" => "", "new_name" => "some-name"}
             })

    assert err["type"] == "invalid_args"
  end

  test "empty new_name → invalid_args" do
    assert {:error, err} =
             WorkspaceRename.execute(%{
               "args" => %{"name" => "some-name", "new_name" => ""}
             })

    assert err["type"] == "invalid_args"
  end
end

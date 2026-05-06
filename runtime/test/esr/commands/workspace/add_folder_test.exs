defmodule Esr.Commands.Workspace.AddFolderTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Workspace.AddFolder, as: WorkspaceAddFolder
  alias Esr.Resource.Workspace.{Struct, Registry}

  # ── Setup / Teardown ──────────────────────────────────────────────────────────

  setup do
    assert is_pid(Process.whereis(Registry))

    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "ws_add_folder_test_#{unique}")
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
      Esr.Resource.Workspace.Bootstrap.run()
    end)

    {:ok, tmp: tmp}
  end

  # Helper: create a tmp git repo for path validation tests
  defp init_tmp_git_repo do
    dir = Path.join(System.tmp_dir!(), "esr-test-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", dir], stderr_to_stdout: true)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Helper: create a plain directory (not a git repo)
  defp init_tmp_dir do
    dir = Path.join(System.tmp_dir!(), "esr-test-plain-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Helper: put a fresh ESR-bound workspace
  defp put_esr_ws(name, id, tmp) do
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

    Registry.put(ws)
    ws
  end

  # Helper: put an ESR-bound workspace with some folders already in it
  defp put_esr_ws_with_folders(name, id, tmp, folders) do
    dir = Path.join([tmp, "default", "workspaces", name])
    File.mkdir_p!(dir)

    ws = %Struct{
      id: id,
      name: name,
      owner: "tester",
      folders: folders,
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

  # ── Happy-path tests ──────────────────────────────────────────────────────────

  # Test 1: ESR-bound workspace, add valid git repo path → ok, folders has 1 entry, persisted
  test "ESR-bound workspace, add valid git repo path → ok, 1 entry persisted", %{tmp: tmp} do
    id = "aaf00001-0001-4000-8000-000000000001"
    put_esr_ws("ws-add-1", id, tmp)
    repo = init_tmp_git_repo()

    assert {:ok, result} =
             WorkspaceAddFolder.execute(%{
               "args" => %{"name" => "ws-add-1", "path" => repo}
             })

    assert result["name"] == "ws-add-1"
    assert result["id"] == id
    assert length(result["folders"]) == 1
    assert hd(result["folders"])["path"] == Path.expand(repo)

    # Verify persisted
    assert {:ok, updated} = Registry.get_by_id(id)
    assert length(updated.folders) == 1
    assert hd(updated.folders).path == Path.expand(repo)
  end

  # Test 2: add to workspace that already has folders → folders count increments by 1
  test "add to workspace that already has folders → count increments by 1", %{tmp: tmp} do
    id = "aaf00002-0002-4000-8000-000000000002"
    first_repo = init_tmp_git_repo()
    put_esr_ws_with_folders("ws-add-2", id, tmp, [%{path: Path.expand(first_repo), name: "first"}])
    second_repo = init_tmp_git_repo()

    assert {:ok, result} =
             WorkspaceAddFolder.execute(%{
               "args" => %{"name" => "ws-add-2", "path" => second_repo}
             })

    assert length(result["folders"]) == 2

    assert {:ok, updated} = Registry.get_by_id(id)
    assert length(updated.folders) == 2
  end

  # Test 3: custom folder_name → uses given display name
  test "custom folder_name → uses given display name in result", %{tmp: tmp} do
    id = "aaf00003-0003-4000-8000-000000000003"
    put_esr_ws("ws-add-3", id, tmp)
    repo = init_tmp_git_repo()

    assert {:ok, result} =
             WorkspaceAddFolder.execute(%{
               "args" => %{"name" => "ws-add-3", "path" => repo, "folder_name" => "my-tools"}
             })

    assert hd(result["folders"])["name"] == "my-tools"

    assert {:ok, updated} = Registry.get_by_id(id)
    assert hd(updated.folders).name == "my-tools"
  end

  # Test 4: omitted folder_name → defaults to Path.basename(path)
  test "omitted folder_name → defaults to Path.basename(path)", %{tmp: tmp} do
    id = "aaf00004-0004-4000-8000-000000000004"
    put_esr_ws("ws-add-4", id, tmp)
    repo = init_tmp_git_repo()

    assert {:ok, result} =
             WorkspaceAddFolder.execute(%{
               "args" => %{"name" => "ws-add-4", "path" => repo}
             })

    assert hd(result["folders"])["name"] == Path.basename(repo)
  end

  # ── Validation error tests ────────────────────────────────────────────────────

  # Test 5: path not absolute → invalid_args
  test "path not absolute → invalid_args error", %{tmp: tmp} do
    id = "aaf00005-0005-4000-8000-000000000005"
    put_esr_ws("ws-add-5", id, tmp)

    assert {:error, err} =
             WorkspaceAddFolder.execute(%{
               "args" => %{"name" => "ws-add-5", "path" => "relative/path"}
             })

    assert err["type"] in ["invalid_args", "path_not_absolute"]
  end

  # Test 6: path doesn't exist → folder_not_dir
  test "path doesn't exist → folder_not_dir error", %{tmp: tmp} do
    id = "aaf00006-0006-4000-8000-000000000006"
    put_esr_ws("ws-add-6", id, tmp)

    assert {:error, err} =
             WorkspaceAddFolder.execute(%{
               "args" => %{"name" => "ws-add-6", "path" => "/absolutely/nonexistent/path/xyz123"}
             })

    assert err["type"] == "folder_not_dir"
  end

  # Test 7: path exists but not a git repo (no .git) → folder_not_git_repo
  test "path exists but no .git → folder_not_git_repo error", %{tmp: tmp} do
    id = "aaf00007-0007-4000-8000-000000000007"
    put_esr_ws("ws-add-7", id, tmp)
    plain_dir = init_tmp_dir()

    assert {:error, err} =
             WorkspaceAddFolder.execute(%{
               "args" => %{"name" => "ws-add-7", "path" => plain_dir}
             })

    assert err["type"] == "folder_not_git_repo"
  end

  # Test 8: duplicate path → folder_already_added
  test "duplicate path → folder_already_added error", %{tmp: tmp} do
    id = "aaf00008-0008-4000-8000-000000000008"
    repo = init_tmp_git_repo()
    put_esr_ws_with_folders("ws-add-8", id, tmp, [%{path: Path.expand(repo), name: "repo"}])

    assert {:error, err} =
             WorkspaceAddFolder.execute(%{
               "args" => %{"name" => "ws-add-8", "path" => repo}
             })

    assert err["type"] == "folder_already_added"
  end

  # Test 9: unknown workspace name → unknown_workspace
  test "unknown workspace name → unknown_workspace error" do
    # Need a valid git repo path so validation passes through to the lookup step
    repo = init_tmp_git_repo()

    assert {:error, err} =
             WorkspaceAddFolder.execute(%{
               "args" => %{"name" => "nonexistent-ws-xyz", "path" => repo}
             })

    assert err["type"] == "unknown_workspace"
    assert err["name"] == "nonexistent-ws-xyz"
  end

  # Test 10: missing args → invalid_args
  test "missing args → invalid_args" do
    assert {:error, err} = WorkspaceAddFolder.execute(%{})
    assert err["type"] == "invalid_args"
  end

  test "missing path arg → invalid_args" do
    assert {:error, err} = WorkspaceAddFolder.execute(%{"args" => %{"name" => "some-ws"}})
    assert err["type"] == "invalid_args"
  end

  test "missing name arg → invalid_args" do
    assert {:error, err} = WorkspaceAddFolder.execute(%{"args" => %{"path" => "/tmp"}})
    assert err["type"] == "invalid_args"
  end

  test "empty name → invalid_args" do
    assert {:error, err} =
             WorkspaceAddFolder.execute(%{"args" => %{"name" => "", "path" => "/tmp"}})

    assert err["type"] == "invalid_args"
  end

  test "empty path → invalid_args" do
    assert {:error, err} =
             WorkspaceAddFolder.execute(%{"args" => %{"name" => "some-ws", "path" => ""}})

    assert err["type"] == "invalid_args"
  end
end

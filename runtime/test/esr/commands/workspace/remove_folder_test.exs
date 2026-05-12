defmodule Esr.Commands.Workspace.RemoveFolderTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Workspace.RemoveFolder, as: WorkspaceRemoveFolder
  alias Esr.Resource.Workspace.{Struct, Registry}

  # ── Setup / Teardown ──────────────────────────────────────────────────────────

  setup do
    assert is_pid(Process.whereis(Registry))

    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "ws_remove_folder_test_#{unique}")
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
    end)

    {:ok, tmp: tmp}
  end

  # Helper: create a tmp git repo for realistic folder entries
  defp init_tmp_git_repo do
    dir = Path.join(System.tmp_dir!(), "esr-test-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", dir], stderr_to_stdout: true)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Helper: put an ESR-bound workspace with given folders
  defp put_esr_ws(name, id, tmp, folders) do
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

  # Helper: put a repo-bound workspace with given folders
  defp put_repo_ws(name, id, repo_path, extra_folders) do
    folders = [%{path: Path.expand(repo_path), name: Path.basename(repo_path)} | extra_folders]

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
      location: {:repo_bound, Path.expand(repo_path)}
    }

    Registry.put(ws)
    ws
  end

  # ── Happy-path tests ──────────────────────────────────────────────────────────

  # Test 1: ESR-bound workspace with one folder, removing it now fails the
  # ≥1-folder invariant (PR-1, spec 2026-05-11 §4.1) — use /workspace:remove
  # to delete the whole workspace instead.
  test "ESR-bound workspace with one folder, removing it → cannot_remove_last_folder",
       %{tmp: tmp} do
    id = "bbf00001-0001-4000-8000-000000000001"
    repo = init_tmp_git_repo()
    put_esr_ws("ws-rm-1", id, tmp, [%{path: Path.expand(repo), name: "repo"}])

    assert {:error, %{"type" => "cannot_remove_last_folder"}} =
             WorkspaceRemoveFolder.execute(%{
               "args" => %{"name" => "ws-rm-1", "path" => repo}
             })

    # State is unchanged after the rejected removal.
    assert {:ok, unchanged} = Registry.get_by_id(id)
    assert length(unchanged.folders) == 1
  end

  # Test 2: ESR-bound, multiple folders, remove middle → ok, others remain
  test "ESR-bound, multiple folders, remove middle → ok, others remain", %{tmp: tmp} do
    id = "bbf00002-0002-4000-8000-000000000002"
    repo_a = init_tmp_git_repo()
    repo_b = init_tmp_git_repo()
    repo_c = init_tmp_git_repo()

    put_esr_ws("ws-rm-2", id, tmp, [
      %{path: Path.expand(repo_a), name: "repo-a"},
      %{path: Path.expand(repo_b), name: "repo-b"},
      %{path: Path.expand(repo_c), name: "repo-c"}
    ])

    assert {:ok, result} =
             WorkspaceRemoveFolder.execute(%{
               "args" => %{"name" => "ws-rm-2", "path" => repo_b}
             })

    assert length(result["folders"]) == 2
    paths = Enum.map(result["folders"], & &1["path"])
    assert Path.expand(repo_b) not in paths
    assert Path.expand(repo_a) in paths
    assert Path.expand(repo_c) in paths

    assert {:ok, updated} = Registry.get_by_id(id)
    assert length(updated.folders) == 2
  end

  # Test 3: Repo-bound workspace with >1 folder, remove folders[0] →
  # cannot_remove_root_folder. (Single-folder repo-bound is covered by the
  # ≥1-folder guard test below — see ":cannot_remove_last_folder guard".)
  test "repo-bound workspace, remove folders[0] → cannot_remove_root_folder", %{tmp: _tmp} do
    id = "bbf00003-0003-4000-8000-000000000003"
    repo = init_tmp_git_repo()
    extra = init_tmp_git_repo()
    put_repo_ws("ws-rm-3", id, repo, [%{path: Path.expand(extra), name: "extra"}])

    assert {:error, err} =
             WorkspaceRemoveFolder.execute(%{
               "args" => %{"name" => "ws-rm-3", "path" => repo}
             })

    assert err["type"] == "cannot_remove_root_folder"
    assert err["message"] =~ "forget-repo"
  end

  # Test 4: Repo-bound workspace, remove a NON-folders[0] entry → ok
  test "repo-bound workspace, remove a NON-folders[0] entry → ok", %{tmp: _tmp} do
    id = "bbf00004-0004-4000-8000-000000000004"
    repo = init_tmp_git_repo()
    extra = init_tmp_git_repo()
    put_repo_ws("ws-rm-4", id, repo, [%{path: Path.expand(extra), name: "extra"}])

    assert {:ok, result} =
             WorkspaceRemoveFolder.execute(%{
               "args" => %{"name" => "ws-rm-4", "path" => extra}
             })

    assert length(result["folders"]) == 1
    assert hd(result["folders"])["path"] == Path.expand(repo)

    assert {:ok, updated} = Registry.get_by_id(id)
    assert length(updated.folders) == 1
  end

  # Test 5: path not in folders → folder_not_in_workspace
  test "path not in folders → folder_not_in_workspace error", %{tmp: tmp} do
    id = "bbf00005-0005-4000-8000-000000000005"
    repo = init_tmp_git_repo()
    put_esr_ws("ws-rm-5", id, tmp, [%{path: Path.expand(repo), name: "repo"}])

    assert {:error, err} =
             WorkspaceRemoveFolder.execute(%{
               "args" => %{"name" => "ws-rm-5", "path" => "/some/other/path/not/in/ws"}
             })

    assert err["type"] == "folder_not_in_workspace"
  end

  # Test 6: unknown workspace → unknown_workspace
  test "unknown workspace → unknown_workspace error" do
    assert {:error, err} =
             WorkspaceRemoveFolder.execute(%{
               "args" => %{"name" => "nonexistent-ws-xyz", "path" => "/some/path"}
             })

    assert err["type"] == "unknown_workspace"
    assert err["message"] =~ "nonexistent-ws-xyz"
  end

  # Test 7: missing args → invalid_args
  test "missing args → invalid_args" do
    assert {:error, err} = WorkspaceRemoveFolder.execute(%{})
    assert err["type"] == "invalid_args"
  end

  test "missing path → invalid_args" do
    assert {:error, err} = WorkspaceRemoveFolder.execute(%{"args" => %{"name" => "some-ws"}})
    assert err["type"] == "invalid_args"
  end

  test "missing name → invalid_args" do
    assert {:error, err} = WorkspaceRemoveFolder.execute(%{"args" => %{"path" => "/some/path"}})
    assert err["type"] == "invalid_args"
  end

  test "empty name → invalid_args" do
    assert {:error, err} =
             WorkspaceRemoveFolder.execute(%{"args" => %{"name" => "", "path" => "/some/path"}})

    assert err["type"] == "invalid_args"
  end

  test "empty path → invalid_args" do
    assert {:error, err} =
             WorkspaceRemoveFolder.execute(%{"args" => %{"name" => "some-ws", "path" => ""}})

    assert err["type"] == "invalid_args"
  end

  # Test 8: result includes "removed" with matched path AND "folders" with remaining list
  test "result shape: includes 'removed' and 'folders' fields", %{tmp: tmp} do
    id = "bbf00008-0008-4000-8000-000000000008"
    repo_a = init_tmp_git_repo()
    repo_b = init_tmp_git_repo()

    put_esr_ws("ws-rm-8", id, tmp, [
      %{path: Path.expand(repo_a), name: "repo-a"},
      %{path: Path.expand(repo_b), name: "repo-b"}
    ])

    assert {:ok, result} =
             WorkspaceRemoveFolder.execute(%{
               "args" => %{"name" => "ws-rm-8", "path" => repo_a}
             })

    # Must have "removed" key with the expanded path
    assert Map.has_key?(result, "removed")
    assert result["removed"] == Path.expand(repo_a)

    # Must have "folders" key with remaining entries as string-keyed maps
    assert Map.has_key?(result, "folders")
    assert is_list(result["folders"])
    assert length(result["folders"]) == 1
    remaining = hd(result["folders"])
    assert Map.has_key?(remaining, "path")
    assert Map.has_key?(remaining, "name")
    assert remaining["path"] == Path.expand(repo_b)
  end

  # ── ≥1-folder invariant guard (spec 2026-05-11 §4.1) ──────────────────────────

  describe ":cannot_remove_last_folder guard" do
    test "removing the only folder fails (created via New.execute, repo-bound)" do
      # Use Esr.Commands.Workspace.New end-to-end so the test exercises the
      # production path; the new workspace has exactly 1 folder.
      if Process.whereis(Esr.Entity.User.Registry) == nil do
        start_supervised!(Esr.Entity.User.Registry)
      end

      Esr.Entity.User.Registry.load_snapshot(%{
        "alice" => %Esr.Entity.User.Struct{
          username: "alice",
          feishu_ids: ["ou_alice"]
        }
      })

      repo = init_tmp_git_repo()
      name = "single-#{:erlang.unique_integer([:positive])}"

      {:ok, _} =
        Esr.Commands.Workspace.New.execute(%{
          "args" => %{"name" => name, "username" => "alice", "folder" => repo}
        })

      # validate_not_last_folder runs BEFORE validate_not_root_folder in
      # execute/1, so repo-bound single-folder also yields
      # :cannot_remove_last_folder (not :cannot_remove_root_folder).
      # We assert that below for the repo-bound case; first we set up an
      # ESR-bound 1-folder workspace to assert the same envelope independently
      # of the root-folder guard.
      esr_name = "esr-single-#{:erlang.unique_integer([:positive])}"

      {:ok, _} =
        Esr.Commands.Workspace.New.execute(%{
          "args" => %{"name" => esr_name, "username" => "alice"}
        })

      {:ok, wid} =
        Esr.Resource.Workspace.NameIndex.id_for_name(:esr_workspace_name_index, esr_name)

      {:ok, ws} = Registry.get_by_id(wid)
      [%{path: only_path}] = ws.folders

      assert {:error, %{"type" => "cannot_remove_last_folder"}} =
               WorkspaceRemoveFolder.execute(%{
                 "args" => %{"name" => esr_name, "path" => only_path}
               })

      # repo-bound case: same workspace, removing its only folder
      assert {:error, %{"type" => "cannot_remove_last_folder"}} =
               WorkspaceRemoveFolder.execute(%{
                 "args" => %{"name" => name, "path" => repo}
               })

      Esr.Entity.User.Registry.load_snapshot(%{})
    end
  end
end

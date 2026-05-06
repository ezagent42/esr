defmodule Esr.Commands.Workspace.ImportRepoTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Workspace.ImportRepo
  alias Esr.Resource.Workspace.Registry
  alias Esr.Paths

  # ── Setup / Teardown ──────────────────────────────────────────────────────────

  setup do
    assert is_pid(Process.whereis(Registry))

    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "ws_import_test_#{unique}")
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

  # Helper: Create a valid workspace.json in a temp repo
  defp create_workspace_repo(tmp, repo_name, id, ws_name) do
    repo_path = Path.join(tmp, repo_name)
    esr_dir = Path.join(repo_path, ".esr")
    File.mkdir_p!(esr_dir)

    workspace_json = %{
      "schema_version" => 1,
      "id" => id,
      "name" => ws_name,
      "owner" => "testuser"
    }

    json_path = Path.join(esr_dir, "workspace.json")
    File.write!(json_path, Jason.encode!(workspace_json))

    repo_path
  end

  # ── Happy-path tests ──────────────────────────────────────────────────────────

  # Test 1: Valid repo with .esr/workspace.json → ok, returns workspace name + id
  test "valid repo with .esr/workspace.json → ok, returns workspace name + id, indexed", %{tmp: tmp} do
    id = UUID.uuid4()
    repo_path = create_workspace_repo(tmp, "myrepo1", id, "myws")

    assert {:ok, result} = ImportRepo.execute(%{"args" => %{"path" => repo_path}})

    assert result["path"] == repo_path
    assert result["name"] == "myws"
    assert result["id"] == id
    assert result["action"] == "imported"

    # Verify Registry.refresh() picked it up
    assert {:ok, ws} = Registry.get_by_id(id)
    assert ws.name == "myws"
  end

  # Test 2: After import, the path is in registered_repos.yaml
  test "after import, path is in registered_repos.yaml", %{tmp: tmp} do
    id = UUID.uuid4()
    repo_path = create_workspace_repo(tmp, "myrepo2", id, "myws2")

    assert {:ok, _result} = ImportRepo.execute(%{"args" => %{"path" => repo_path}})

    # Read the yaml and check
    yaml_path = Paths.registered_repos_yaml()
    {:ok, entries} = Esr.Resource.Workspace.RepoRegistry.load(yaml_path)
    assert Enum.any?(entries, &(&1.path == repo_path))
  end

  # Test 3: Re-importing the same path is idempotent (no error, no duplication)
  test "re-importing the same path is idempotent", %{tmp: tmp} do
    id = UUID.uuid4()
    repo_path = create_workspace_repo(tmp, "myrepo3", id, "myws3")

    # First import
    assert {:ok, result1} = ImportRepo.execute(%{"args" => %{"path" => repo_path}})
    assert result1["action"] == "imported"

    # Second import (same path)
    assert {:ok, result2} = ImportRepo.execute(%{"args" => %{"path" => repo_path}})
    assert result2["action"] == "imported"

    # Verify no duplication in yaml
    yaml_path = Paths.registered_repos_yaml()
    {:ok, entries} = Esr.Resource.Workspace.RepoRegistry.load(yaml_path)
    matches = Enum.filter(entries, &(&1.path == repo_path))
    assert length(matches) == 1
  end

  # ── Error cases ───────────────────────────────────────────────────────────────

  # Test 4: Path doesn't exist → path_not_dir
  test "path doesn't exist → path_not_dir", %{tmp: _tmp} do
    nonexistent = "/tmp/nonexistent_path_#{System.unique_integer([:positive])}"

    assert {:error, err} = ImportRepo.execute(%{"args" => %{"path" => nonexistent}})
    assert err["type"] == "path_not_dir"
    assert err["path"] == nonexistent
  end

  # Test 5: Path exists but no .esr/workspace.json → not_a_workspace_repo
  test "path exists but no .esr/workspace.json → not_a_workspace_repo", %{tmp: tmp} do
    repo_path = Path.join(tmp, "nows_repo")
    File.mkdir_p!(repo_path)

    assert {:error, err} = ImportRepo.execute(%{"args" => %{"path" => repo_path}})
    assert err["type"] == "not_a_workspace_repo"
    assert err["path"] == repo_path
  end

  # Test 6: .esr/workspace.json exists but is malformed JSON → invalid_workspace_json
  test "malformed JSON → invalid_workspace_json", %{tmp: tmp} do
    repo_path = Path.join(tmp, "bad_json_repo")
    esr_dir = Path.join(repo_path, ".esr")
    File.mkdir_p!(esr_dir)

    # Write invalid JSON
    json_path = Path.join(esr_dir, "workspace.json")
    File.write!(json_path, "{not json")

    assert {:error, err} = ImportRepo.execute(%{"args" => %{"path" => repo_path}})
    assert err["type"] == "invalid_workspace_json"
    assert err["path"] == repo_path
    assert is_binary(err["detail"])
  end

  # Test 7: Missing args → invalid_args
  test "args missing → invalid_args" do
    assert {:error, err} = ImportRepo.execute(%{})
    assert err["type"] == "invalid_args"
  end

  test "args path missing → invalid_args" do
    assert {:error, err} = ImportRepo.execute(%{"args" => %{}})
    assert err["type"] == "invalid_args"
  end

  test "args path empty → invalid_args" do
    assert {:error, err} = ImportRepo.execute(%{"args" => %{"path" => ""}})
    assert err["type"] == "invalid_args"
  end

  # Test 8: Relative path → invalid_args
  test "relative path → invalid_args" do
    assert {:error, err} = ImportRepo.execute(%{"args" => %{"path" => "relative/path"}})
    assert err["type"] == "invalid_args"
    assert err["message"] =~ "absolute"
  end
end

defmodule Esr.Commands.Workspace.ForgetRepoTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Workspace.ForgetRepo
  alias Esr.Resource.Workspace.{Registry, RepoRegistry}
  alias Esr.Paths

  # ── Setup / Teardown ──────────────────────────────────────────────────────────

  setup do
    assert is_pid(Process.whereis(Registry))

    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "ws_forget_test_#{unique}")
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

  # Test 1: Setup: register a repo, then forget it. Assert action="forgotten", yaml no longer contains path.
  test "registered repo forgotten → action=forgotten, removed from yaml", %{tmp: tmp} do
    id = UUID.uuid4()
    repo_path = create_workspace_repo(tmp, "myrepo1", id, "myws1")

    # Register the repo first
    yaml_path = Paths.registered_repos_yaml()
    assert :ok = RepoRegistry.register(yaml_path, repo_path)
    assert :ok = Registry.refresh()

    # Verify it's in the yaml
    {:ok, entries_before} = RepoRegistry.load(yaml_path)
    assert Enum.any?(entries_before, &(&1.path == repo_path))

    # Forget it
    assert {:ok, result} = ForgetRepo.execute(%{"args" => %{"path" => repo_path}})
    assert result["path"] == repo_path
    assert result["action"] == "forgotten"

    # Verify it's no longer in the yaml
    {:ok, entries_after} = RepoRegistry.load(yaml_path)
    assert not Enum.any?(entries_after, &(&1.path == repo_path))
  end

  # Test 2: Forgetting an already-unregistered path returns action="already_forgotten" (no error)
  test "unregistered path forgetting → action=already_forgotten (idempotent)", %{tmp: tmp} do
    repo_path = Path.join(tmp, "never_registered")
    File.mkdir_p!(repo_path)

    assert {:ok, result} = ForgetRepo.execute(%{"args" => %{"path" => repo_path}})
    assert result["path"] == repo_path
    assert result["action"] == "already_forgotten"
  end

  # Test 3: Forgetting a path that was never registered → action="already_forgotten"
  test "never-registered path → action=already_forgotten", %{tmp: tmp} do
    repo_path = Path.join(tmp, "never_touched")

    assert {:ok, result} = ForgetRepo.execute(%{"args" => %{"path" => repo_path}})
    assert result["action"] == "already_forgotten"
  end

  # Test 4: After forget, Registry.refresh() does NOT include the workspace anymore
  test "after forget, workspace not found by Registry.get_by_id", %{tmp: tmp} do
    id = UUID.uuid4()
    repo_path = create_workspace_repo(tmp, "myrepo4", id, "myws4")

    # Register and refresh
    yaml_path = Paths.registered_repos_yaml()
    assert :ok = RepoRegistry.register(yaml_path, repo_path)
    assert :ok = Registry.refresh()

    # Verify it's in the registry
    assert {:ok, _ws} = Registry.get_by_id(id)

    # Forget it
    assert {:ok, _result} = ForgetRepo.execute(%{"args" => %{"path" => repo_path}})

    # Verify it's no longer in the registry
    assert :not_found = Registry.get_by_id(id)
  end

  # ── Error cases ───────────────────────────────────────────────────────────────

  # Test 5: Missing args → invalid_args
  test "args missing → invalid_args" do
    assert {:error, err} = ForgetRepo.execute(%{})
    assert err["type"] == "invalid_args"
  end

  test "args path missing → invalid_args" do
    assert {:error, err} = ForgetRepo.execute(%{"args" => %{}})
    assert err["type"] == "invalid_args"
  end

  test "args path empty → invalid_args" do
    assert {:error, err} = ForgetRepo.execute(%{"args" => %{"path" => ""}})
    assert err["type"] == "invalid_args"
  end
end

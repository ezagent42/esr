defmodule Esr.Commands.Workspace.RemoveTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Workspace.Remove, as: WorkspaceRemove
  alias Esr.Resource.Workspace.{Struct, Registry, NameIndex, RepoRegistry}

  # ── Setup / Teardown ──────────────────────────────────────────────────────────

  setup do
    assert is_pid(Process.whereis(Registry))

    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "ws_remove_test_#{unique}")
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
      Application.delete_env(:esr, :workspace_active_sessions_fn)
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

  # Helper: put a fresh repo-bound workspace with files on disk
  defp put_repo_ws(name, id, repo_path) do
    esr_dir = Path.join(repo_path, ".esr")
    File.mkdir_p!(esr_dir)

    ws_json = Path.join(esr_dir, "workspace.json")

    File.write!(ws_json,
      Jason.encode!(%{
        "schema_version" => 1,
        "id" => id,
        "name" => name,
        "owner" => "tester"
      })
    )

    ws = %Struct{
      id: id,
      name: name,
      owner: "tester",
      folders: [%{path: repo_path, name: name}],
      agent: "cc",
      settings: %{},
      env: %{},
      chats: [],
      transient: false,
      location: {:repo_bound, repo_path}
    }

    :ok = Registry.put(ws)
    ws
  end

  # ── Test 1 (Sentinel): repo-bound remove preserves other .esr/ files ─────────

  test "repo-bound /workspace remove preserves other files in <repo>/.esr/", %{tmp: tmp} do
    repo = Path.join(tmp, "myrepo")
    esr_dir = Path.join(repo, ".esr")
    File.mkdir_p!(esr_dir)

    id = UUID.uuid4()

    # workspace.json + topology.yaml — both should be removed
    File.write!(
      Path.join(esr_dir, "workspace.json"),
      Jason.encode!(%{
        "schema_version" => 1,
        "id" => id,
        "name" => "myrepo",
        "owner" => "tester"
      })
    )

    File.write!(Path.join(esr_dir, "topology.yaml"), "schema_version: 1\ndescription: x")

    # SENTINEL: agents.yaml is a v2+ feature; an operator may have pre-created it.
    # /workspace remove must NOT rm -rf the .esr/ directory wholesale.
    File.write!(Path.join(esr_dir, "agents.yaml"), "DO_NOT_DELETE")

    # Register repo + workspace
    RepoRegistry.register(Esr.Paths.registered_repos_yaml(), repo)

    ws = %Struct{
      id: id,
      name: "myrepo",
      owner: "tester",
      folders: [%{path: repo, name: "myrepo"}],
      agent: "cc",
      settings: %{},
      env: %{},
      chats: [],
      transient: false,
      location: {:repo_bound, repo}
    }

    :ok = Registry.put(ws)

    # Remove
    assert {:ok, result} =
             WorkspaceRemove.execute(%{"args" => %{"name" => "myrepo"}})

    # Removed files
    refute File.exists?(Path.join(esr_dir, "workspace.json"))
    refute File.exists?(Path.join(esr_dir, "topology.yaml"))

    # SENTINEL — must survive
    assert File.read!(Path.join(esr_dir, "agents.yaml")) == "DO_NOT_DELETE"

    # The .esr/ dir + repo dir themselves must still exist
    assert File.dir?(esr_dir)
    assert File.dir?(repo)

    # Result shape includes expected keys
    assert result["name"] == "myrepo"
    assert result["id"] == id
    assert result["location"] == "repo:#{repo}"
  end

  # ── Test 2: ESR-bound remove deletes the whole workspace dir ─────────────────

  test "ESR-bound /workspace remove deletes entire workspace directory", %{tmp: tmp} do
    id = UUID.uuid4()
    ws = put_esr_ws("esr-ws-del", id, tmp)

    {:esr_bound, dir} = ws.location

    # Verify dir exists before remove
    assert File.dir?(dir)

    assert {:ok, result} =
             WorkspaceRemove.execute(%{"args" => %{"name" => "esr-ws-del"}})

    # Directory is gone
    refute File.exists?(dir)

    assert result["name"] == "esr-ws-del"
    assert result["id"] == id
    assert result["location"] == "esr:#{dir}"
    assert is_list(result["deleted_files"])
  end

  # ── Test 3: Registry cleared after remove ────────────────────────────────────

  test "after remove, Registry.get_by_id and NameIndex return :not_found", %{tmp: tmp} do
    id = UUID.uuid4()
    put_esr_ws("esr-ws-gone", id, tmp)

    assert {:ok, _} = WorkspaceRemove.execute(%{"args" => %{"name" => "esr-ws-gone"}})

    assert Registry.get_by_id(id) == :not_found
    assert NameIndex.id_for_name(:esr_workspace_name_index, "esr-ws-gone") == :not_found
  end

  # ── Test 4: Repo-bound remove unregisters from registered_repos.yaml ─────────

  test "repo-bound remove also unregisters from registered_repos.yaml", %{tmp: tmp} do
    repo = Path.join(tmp, "testrepo")
    id = UUID.uuid4()

    put_repo_ws("testrepo-ws", id, repo)

    yaml_path = Esr.Paths.registered_repos_yaml()
    RepoRegistry.register(yaml_path, repo)

    # Confirm registered before remove
    {:ok, repos_before} = RepoRegistry.load(yaml_path)
    assert Enum.any?(repos_before, &(&1.path == repo))

    assert {:ok, _result} =
             WorkspaceRemove.execute(%{"args" => %{"name" => "testrepo-ws"}})

    # Confirm unregistered after remove
    {:ok, repos_after} = RepoRegistry.load(yaml_path)
    refute Enum.any?(repos_after, &(&1.path == repo))
  end

  # ── Test 5: Active sessions blocked without force ────────────────────────────

  test "active sessions present without force=true → workspace_in_use error", %{tmp: tmp} do
    id = UUID.uuid4()
    put_esr_ws("esr-ws-busy", id, tmp)

    # Inject a non-empty active sessions list
    Application.put_env(:esr, :workspace_active_sessions_fn, fn _id ->
      ["session-abc-123"]
    end)

    assert {:error, err} =
             WorkspaceRemove.execute(%{"args" => %{"name" => "esr-ws-busy"}})

    assert err["type"] == "workspace_in_use"
    assert err["name"] == "esr-ws-busy"
    assert is_list(err["sessions"])
    assert length(err["sessions"]) > 0

    # Workspace still in registry
    assert {:ok, _} = Registry.get_by_id(id)
  end

  # ── Test 6: Active sessions + force=true → succeeds ─────────────────────────

  test "active sessions present with force=true → succeeds and removes", %{tmp: tmp} do
    id = UUID.uuid4()
    ws = put_esr_ws("esr-ws-forced", id, tmp)

    {:esr_bound, dir} = ws.location

    Application.put_env(:esr, :workspace_active_sessions_fn, fn _id ->
      ["session-xyz-999"]
    end)

    assert {:ok, result} =
             WorkspaceRemove.execute(%{
               "args" => %{"name" => "esr-ws-forced", "force" => "true"}
             })

    # Removed successfully
    refute File.exists?(dir)
    assert result["name"] == "esr-ws-forced"
    assert Registry.get_by_id(id) == :not_found
  end

  # ── Test 7: Repo-bound remove when topology.yaml is missing ──────────────────

  test "repo-bound remove when topology.yaml is missing → no error, workspace.json removed", %{
    tmp: tmp
  } do
    repo = Path.join(tmp, "notoporepo")
    id = UUID.uuid4()

    put_repo_ws("notopo-ws", id, repo)
    RepoRegistry.register(Esr.Paths.registered_repos_yaml(), repo)

    ws_json = Path.join([repo, ".esr", "workspace.json"])

    # Confirm no topology.yaml exists
    refute File.exists?(Path.join([repo, ".esr", "topology.yaml"]))

    assert {:ok, result} =
             WorkspaceRemove.execute(%{"args" => %{"name" => "notopo-ws"}})

    # workspace.json removed, no error
    refute File.exists?(ws_json)
    assert result["name"] == "notopo-ws"
  end

  # ── Test 8: Unknown workspace name → unknown_workspace ───────────────────────

  test "unknown workspace name → unknown_workspace error" do
    assert {:error, err} =
             WorkspaceRemove.execute(%{"args" => %{"name" => "totally-nonexistent"}})

    assert err["type"] == "unknown_workspace"
    assert err["name"] == "totally-nonexistent"
  end

  # ── Test 9: Missing args → invalid_args ──────────────────────────────────────

  test "missing args → invalid_args" do
    assert {:error, err} = WorkspaceRemove.execute(%{})
    assert err["type"] == "invalid_args"
  end

  test "args name missing → invalid_args" do
    assert {:error, err} = WorkspaceRemove.execute(%{"args" => %{}})
    assert err["type"] == "invalid_args"
  end

  test "args name empty → invalid_args" do
    assert {:error, err} = WorkspaceRemove.execute(%{"args" => %{"name" => ""}})
    assert err["type"] == "invalid_args"
  end

  # ── Test 10: Result map shape ────────────────────────────────────────────────

  test "result map has name, id, location, deleted_files", %{tmp: tmp} do
    id = UUID.uuid4()
    put_esr_ws("esr-ws-shape", id, tmp)

    assert {:ok, result} =
             WorkspaceRemove.execute(%{"args" => %{"name" => "esr-ws-shape"}})

    assert Map.has_key?(result, "name")
    assert Map.has_key?(result, "id")
    assert Map.has_key?(result, "location")
    assert Map.has_key?(result, "deleted_files")
    assert is_list(result["deleted_files"])
  end
end

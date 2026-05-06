defmodule Esr.Commands.Workspace.EditTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Workspace.Edit, as: WorkspaceEdit
  alias Esr.Resource.Workspace.{Struct, Registry}

  # ── Setup / Teardown ──────────────────────────────────────────────────────────

  setup do
    assert is_pid(Process.whereis(Registry))

    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "ws_edit_test_#{unique}")
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

  # ── Happy-path tests ──────────────────────────────────────────────────────────

  # Test 1: agent=claude → top-level agent field updated
  test "agent=claude happy path → ok, agent updated, persisted", %{tmp: tmp} do
    id = "aaaaaaaa-0001-4000-8000-000000000001"
    put_esr_ws("ws-agent", id, tmp)

    assert {:ok, result} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-agent", "set" => "agent=claude"}})

    assert result["name"] == "ws-agent"
    assert result["id"] == id
    assert result["field"] == "agent"
    assert result["value"] == "claude"

    # Verify persisted
    assert {:ok, updated} = Registry.get_by_id(id)
    assert updated.agent == "claude"
  end

  # Test 2: env.PROJECT_ENV=dev → env map entry
  test "env.PROJECT_ENV=dev → ok, env map gets the entry", %{tmp: tmp} do
    id = "aaaaaaaa-0002-4000-8000-000000000002"
    put_esr_ws("ws-env", id, tmp)

    assert {:ok, result} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-env", "set" => "env.PROJECT_ENV=dev"}})

    assert result["field"] == "env.PROJECT_ENV"
    assert result["value"] == "dev"

    assert {:ok, updated} = Registry.get_by_id(id)
    assert updated.env["PROJECT_ENV"] == "dev"
  end

  # Test 3: settings.cc.model=opus → flat dot-string key
  test "settings.cc.model=opus → ok, settings flat dot-string key", %{tmp: tmp} do
    id = "aaaaaaaa-0003-4000-8000-000000000003"
    put_esr_ws("ws-settings", id, tmp)

    assert {:ok, result} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-settings", "set" => "settings.cc.model=opus"}})

    assert result["field"] == "settings.cc.model"
    assert result["value"] == "opus"

    assert {:ok, updated} = Registry.get_by_id(id)
    assert updated.settings["cc.model"] == "opus"
  end

  # Test 4: settings.cc.allowed_tools=Bash,Edit,Read → list value parsed
  test "settings.cc.allowed_tools=Bash,Edit,Read → list value parsed", %{tmp: tmp} do
    id = "aaaaaaaa-0004-4000-8000-000000000004"
    put_esr_ws("ws-list", id, tmp)

    assert {:ok, result} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-list", "set" => "settings.cc.allowed_tools=Bash,Edit,Read"}})

    assert result["value"] == ["Bash", "Edit", "Read"]

    assert {:ok, updated} = Registry.get_by_id(id)
    assert updated.settings["cc.allowed_tools"] == ["Bash", "Edit", "Read"]
  end

  # Test 5: settings.cc.timeout=42 → integer parsed
  test "settings.cc.timeout=42 → integer parsed", %{tmp: tmp} do
    id = "aaaaaaaa-0005-4000-8000-000000000005"
    put_esr_ws("ws-int", id, tmp)

    assert {:ok, result} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-int", "set" => "settings.cc.timeout=42"}})

    assert result["value"] == 42

    assert {:ok, updated} = Registry.get_by_id(id)
    assert updated.settings["cc.timeout"] == 42
  end

  # Test 6: settings.logging.enabled=true → boolean true
  test "settings.logging.enabled=true → boolean true", %{tmp: tmp} do
    id = "aaaaaaaa-0006-4000-8000-000000000006"
    put_esr_ws("ws-bool-t", id, tmp)

    assert {:ok, result} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-bool-t", "set" => "settings.logging.enabled=true"}})

    assert result["value"] == true

    assert {:ok, updated} = Registry.get_by_id(id)
    assert updated.settings["logging.enabled"] == true
  end

  # Test 7: settings.logging.enabled=false → boolean false
  test "settings.logging.enabled=false → boolean false", %{tmp: tmp} do
    id = "aaaaaaaa-0007-4000-8000-000000000007"
    put_esr_ws("ws-bool-f", id, tmp)

    assert {:ok, result} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-bool-f", "set" => "settings.logging.enabled=false"}})

    assert result["value"] == false

    assert {:ok, updated} = Registry.get_by_id(id)
    assert updated.settings["logging.enabled"] == false
  end

  # Test 21: transient=true on ESR-bound → ok, becomes transient
  test "transient=true on ESR-bound → ok, becomes transient", %{tmp: tmp} do
    id = "aaaaaaaa-0021-4000-8000-000000000021"
    put_esr_ws("ws-transient-esr", id, tmp)

    assert {:ok, result} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-transient-esr", "set" => "transient=true"}})

    assert result["field"] == "transient"
    assert result["value"] == true

    assert {:ok, updated} = Registry.get_by_id(id)
    assert updated.transient == true
  end

  # ── Locked field errors ───────────────────────────────────────────────────────

  # Test 8: name=other → field_locked
  test "name=other → field_locked error", %{tmp: tmp} do
    id = "aaaaaaaa-0008-4000-8000-000000000008"
    put_esr_ws("ws-locked", id, tmp)

    assert {:error, err} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-locked", "set" => "name=other"}})
    assert err["type"] == "field_locked"
    assert err["field"] == "name"
  end

  # Test 9: id=... → field_locked
  test "id=... → field_locked", %{tmp: tmp} do
    id = "aaaaaaaa-0009-4000-8000-000000000009"
    put_esr_ws("ws-locked2", id, tmp)

    assert {:error, err} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-locked2", "set" => "id=newid"}})
    assert err["type"] == "field_locked"
    assert err["field"] == "id"
  end

  # Test 10: chats=... → field_locked
  test "chats=... → field_locked", %{tmp: tmp} do
    id = "aaaaaaaa-0010-4000-8000-000000000010"
    put_esr_ws("ws-locked3", id, tmp)

    assert {:error, err} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-locked3", "set" => "chats=something"}})
    assert err["type"] == "field_locked"
    assert err["field"] == "chats"
  end

  # Test 11: folders=... → field_locked
  test "folders=... → field_locked", %{tmp: tmp} do
    id = "aaaaaaaa-0011-4000-8000-000000000011"
    put_esr_ws("ws-locked4", id, tmp)

    assert {:error, err} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-locked4", "set" => "folders=something"}})
    assert err["type"] == "field_locked"
    assert err["field"] == "folders"
  end

  # Test 12: location=... → field_locked
  test "location=... → field_locked", %{tmp: tmp} do
    id = "aaaaaaaa-0012-4000-8000-000000000012"
    put_esr_ws("ws-locked5", id, tmp)

    assert {:error, err} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-locked5", "set" => "location=something"}})
    assert err["type"] == "field_locked"
    assert err["field"] == "location"
  end

  # ── Unknown / invalid field errors ───────────────────────────────────────────

  # Test 13: unknown_top=x → unknown_field error
  test "unknown_top=x → unknown_field error", %{tmp: tmp} do
    id = "aaaaaaaa-0013-4000-8000-000000000013"
    put_esr_ws("ws-unknown", id, tmp)

    assert {:error, err} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-unknown", "set" => "unknown_top=x"}})
    assert err["type"] == "unknown_field"
    assert err["field"] == "unknown_top"
  end

  # Test 14: agent.nested=x → invalid_field (agent does not accept dotted suffix)
  test "agent.nested=x → invalid_field (agent does not accept dotted suffix)", %{tmp: tmp} do
    id = "aaaaaaaa-0014-4000-8000-000000000014"
    put_esr_ws("ws-agent-dot", id, tmp)

    assert {:error, err} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-agent-dot", "set" => "agent.nested=x"}})
    assert err["type"] == "invalid_field"
    assert err["message"] =~ "agent does not accept dotted suffix"
  end

  # Test 15: env=x (no .) → invalid_env_key
  test "env=x (no dot) → invalid_env_key", %{tmp: tmp} do
    id = "aaaaaaaa-0015-4000-8000-000000000015"
    put_esr_ws("ws-env-nodot", id, tmp)

    assert {:error, err} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-env-nodot", "set" => "env=x"}})
    assert err["type"] == "invalid_env_key"
    assert err["message"] =~ "env requires env.<NAME>=<value>"
  end

  # Test 16: env.A.B=x (env with dot in key) → invalid_env_key
  test "env.A.B=x (env key with dot) → invalid_env_key", %{tmp: tmp} do
    id = "aaaaaaaa-0016-4000-8000-000000000016"
    put_esr_ws("ws-env-dot", id, tmp)

    assert {:error, err} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-env-dot", "set" => "env.A.B=x"}})
    assert err["type"] == "invalid_env_key"
    assert err["message"] =~ "env keys cannot contain dots"
  end

  # ── set format errors ─────────────────────────────────────────────────────────

  # Test 17: set missing = → invalid_set error
  test "set missing = → invalid_set error", %{tmp: tmp} do
    id = "aaaaaaaa-0017-4000-8000-000000000017"
    put_esr_ws("ws-noequal", id, tmp)

    assert {:error, err} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-noequal", "set" => "agentclaude"}})
    assert err["type"] == "invalid_set"
    assert err["message"] =~ "key=value"
  end

  # ── Lookup errors ─────────────────────────────────────────────────────────────

  # Test 18: workspace not found → unknown_workspace
  test "workspace not found → unknown_workspace error" do
    assert {:error, err} = WorkspaceEdit.execute(%{"args" => %{"name" => "nonexistent-ws", "set" => "agent=claude"}})
    assert err["type"] == "unknown_workspace"
    assert err["name"] == "nonexistent-ws"
  end

  # ── Args errors ───────────────────────────────────────────────────────────────

  # Test 19: args missing → invalid_args (the catchall clause)
  test "args missing → invalid_args" do
    assert {:error, err} = WorkspaceEdit.execute(%{})
    assert err["type"] == "invalid_args"
  end

  test "args name missing → invalid_args" do
    assert {:error, err} = WorkspaceEdit.execute(%{"args" => %{"set" => "agent=claude"}})
    assert err["type"] == "invalid_args"
  end

  test "args set missing → invalid_args" do
    assert {:error, err} = WorkspaceEdit.execute(%{"args" => %{"name" => "some-ws"}})
    assert err["type"] == "invalid_args"
  end

  test "args name empty → invalid_args" do
    assert {:error, err} = WorkspaceEdit.execute(%{"args" => %{"name" => "", "set" => "agent=claude"}})
    assert err["type"] == "invalid_args"
  end

  test "args set empty → invalid_args" do
    assert {:error, err} = WorkspaceEdit.execute(%{"args" => %{"name" => "some-ws", "set" => ""}})
    assert err["type"] == "invalid_args"
  end

  # ── transient-specific errors ─────────────────────────────────────────────────

  # Test 20: transient=true on repo-bound → transient_repo_bound_forbidden
  test "transient=true on repo-bound workspace → transient_repo_bound_forbidden", %{tmp: tmp} do
    id = "aaaaaaaa-0020-4000-8000-000000000020"
    repo_path = Path.join(tmp, "fake-repo")
    put_repo_ws("ws-repo-transient", id, repo_path)

    assert {:error, err} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-repo-transient", "set" => "transient=true"}})
    assert err["type"] == "transient_repo_bound_forbidden"
  end

  # Test 22: transient=foo → invalid_value (must be boolean)
  test "transient=foo → invalid_value", %{tmp: tmp} do
    id = "aaaaaaaa-0022-4000-8000-000000000022"
    put_esr_ws("ws-transient-bad", id, tmp)

    assert {:error, err} = WorkspaceEdit.execute(%{"args" => %{"name" => "ws-transient-bad", "set" => "transient=foo"}})
    assert err["type"] == "invalid_value"
    assert err["field"] == "transient"
  end
end

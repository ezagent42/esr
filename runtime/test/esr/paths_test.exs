defmodule Esr.PathsTest do
  use ExUnit.Case, async: false

  setup do
    # Snapshot + restore env
    home = System.get_env("ESRD_HOME")
    inst = System.get_env("ESR_INSTANCE")
    on_exit(fn ->
      if home, do: System.put_env("ESRD_HOME", home), else: System.delete_env("ESRD_HOME")
      if inst, do: System.put_env("ESR_INSTANCE", inst), else: System.delete_env("ESR_INSTANCE")
    end)
    System.put_env("ESRD_HOME", "/tmp/pth-test")
    System.delete_env("ESR_INSTANCE")
    :ok
  end

  test "esrd_home reads env" do
    assert Esr.Paths.esrd_home() == "/tmp/pth-test"
  end

  test "current_instance defaults to 'default'" do
    assert Esr.Paths.current_instance() == "default"
  end

  test "current_instance reads env" do
    System.put_env("ESR_INSTANCE", "dev")
    assert Esr.Paths.current_instance() == "dev"
  end

  test "runtime_home composes" do
    System.put_env("ESR_INSTANCE", "dev")
    assert Esr.Paths.runtime_home() == "/tmp/pth-test/dev"
  end

  test "yaml helpers" do
    assert Esr.Paths.capabilities_yaml() == "/tmp/pth-test/default/capabilities.yaml"
    assert Esr.Paths.adapters_yaml() == "/tmp/pth-test/default/adapters.yaml"
    assert Esr.Paths.workspaces_yaml() == "/tmp/pth-test/default/workspaces.yaml"
  end

  test "commands_compiled_dir" do
    assert Esr.Paths.commands_compiled_dir() == "/tmp/pth-test/default/commands/.compiled"
  end

  test "admin_queue_dir" do
    assert Esr.Paths.admin_queue_dir() == "/tmp/pth-test/default/admin_queue"
  end

  test "workspace_json_esr/1 builds correct path under ESRD_HOME" do
    assert Esr.Paths.workspace_json_esr("esr-dev") ==
             "/tmp/pth-test/default/workspaces/esr-dev/workspace.json"
  end

  test "workspace_json_repo/1 puts .esr/workspace.json in the repo" do
    assert Esr.Paths.workspace_json_repo("/tmp/myrepo") ==
             "/tmp/myrepo/.esr/workspace.json"
  end

  test "registered_repos_yaml lives at runtime_home root" do
    assert Esr.Paths.registered_repos_yaml() ==
             "/tmp/pth-test/default/registered_repos.yaml"
  end

  # Phase 1b.5 additions

  test "users_dir/0 builds correct path" do
    assert Esr.Paths.users_dir() == "/tmp/pth-test/default/users"
  end

  test "user_dir/1 builds correct path" do
    uuid = "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
    assert Esr.Paths.user_dir(uuid) ==
             "/tmp/pth-test/default/users/#{uuid}"
  end

  test "user_json/1 builds correct path" do
    uuid = "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
    assert Esr.Paths.user_json(uuid) ==
             "/tmp/pth-test/default/users/#{uuid}/user.json"
  end

  test "user_workspace_json/1 builds correct path" do
    uuid = "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
    assert Esr.Paths.user_workspace_json(uuid) ==
             "/tmp/pth-test/default/users/#{uuid}/.esr/workspace.json"
  end

  test "user_plugins_yaml/1 builds correct path" do
    uuid = "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
    assert Esr.Paths.user_plugins_yaml(uuid) ==
             "/tmp/pth-test/default/users/#{uuid}/.esr/plugins.yaml"
  end

  test "workspace_plugins_yaml/1 builds correct path" do
    assert Esr.Paths.workspace_plugins_yaml("/tmp/myrepo") ==
             "/tmp/myrepo/.esr/plugins.yaml"
  end
end

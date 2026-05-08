defmodule Esr.Entity.User.MigrationTest do
  use ExUnit.Case, async: true
  alias Esr.Entity.User.Migration

  setup do
    tmp = Path.join(System.tmp_dir!(), "user_mig_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "default")
    inst_dir = Path.join([tmp, "default"])
    File.mkdir_p!(inst_dir)
    on_exit(fn ->
      System.delete_env("ESRD_HOME")
      System.delete_env("ESR_INSTANCE")
      File.rm_rf!(tmp)
    end)
    %{tmp: tmp, inst_dir: inst_dir}
  end

  defp write_users_yaml(inst_dir, content) do
    File.write!(Path.join(inst_dir, "users.yaml"), content)
  end

  test "no-op when users.yaml does not exist", %{inst_dir: inst_dir} do
    assert :ok = Migration.run(inst_dir)
    refute File.exists?(Path.join(inst_dir, "users"))
  end

  test "creates users/<uuid>/user.json for each entry", %{inst_dir: inst_dir} do
    write_users_yaml(inst_dir, """
    users:
      linyilun:
        feishu_ids:
          - ou_aaabbbccc
    """)

    assert :ok = Migration.run(inst_dir)

    users_dir = Path.join(inst_dir, "users")
    assert File.exists?(users_dir)
    uuids = File.ls!(users_dir)
    assert length(uuids) == 1
    [uuid] = uuids
    user_json_path = Path.join([users_dir, uuid, "user.json"])
    assert File.exists?(user_json_path)
    {:ok, doc} = Jason.decode(File.read!(user_json_path))
    assert doc["username"] == "linyilun"
    assert doc["id"] == uuid
    assert doc["schema_version"] == 1
  end

  test "creates .esr/workspace.json stub for each user", %{inst_dir: inst_dir} do
    write_users_yaml(inst_dir, """
    users:
      alice:
        feishu_ids: []
    """)

    Migration.run(inst_dir)
    users_dir = Path.join(inst_dir, "users")
    [uuid] = File.ls!(users_dir)
    ws_json = Path.join([users_dir, uuid, ".esr", "workspace.json"])
    assert File.exists?(ws_json)
    {:ok, doc} = Jason.decode(File.read!(ws_json))
    assert doc["kind"] == "user-default"
    assert doc["owner"] == uuid
    assert doc["schema_version"] == 1
  end

  test "renames users.yaml to users.yaml.migrated-<timestamp>", %{inst_dir: inst_dir} do
    write_users_yaml(inst_dir, "users:\n  bob:\n    feishu_ids: []\n")
    Migration.run(inst_dir)
    refute File.exists?(Path.join(inst_dir, "users.yaml"))
    backups = Path.join(inst_dir, "users.yaml.migrated-*") |> Path.wildcard()
    assert length(backups) == 1
  end

  test "idempotent: running twice does not duplicate entries", %{inst_dir: inst_dir} do
    write_users_yaml(inst_dir, "users:\n  carol:\n    feishu_ids: []\n")
    Migration.run(inst_dir)
    # users.yaml was renamed; second run is a no-op
    assert :ok = Migration.run(inst_dir)
    users_dir = Path.join(inst_dir, "users")
    assert length(File.ls!(users_dir)) == 1
  end
end

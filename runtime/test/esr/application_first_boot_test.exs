defmodule Esr.ApplicationFirstBootTest do
  use ExUnit.Case, async: false

  alias Esr.Resource.Workspace.{Bootstrap, Registry}

  # NameIndex + Registry are started by Esr.Application; do not double-start.
  # The legacy-yaml path is driven by $ESRD_HOME, which we override per-test.
  # The default-workspace assertions run against the live application Registry —
  # the application's own Bootstrap already created "default" at boot, so the
  # tests verify idempotency + survival across re-invocations.

  setup do
    tmp = Path.join(System.tmp_dir!(), "esr-firstboot-#{:erlang.unique_integer([:positive])}")
    runtime_home = Path.join(tmp, "default")
    File.mkdir_p!(runtime_home)

    prev_esrd_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)

      if prev_esrd_home,
        do: System.put_env("ESRD_HOME", prev_esrd_home),
        else: System.delete_env("ESRD_HOME")
    end)

    {:ok, tmp: tmp, runtime_home: runtime_home}
  end

  describe "delete_legacy_yaml" do
    test "deletes a stale workspaces.yaml + logs warning", %{runtime_home: runtime_home} do
      legacy = Path.join(runtime_home, "workspaces.yaml")
      File.write!(legacy, "workspaces:\n  - name: stale\n    role: dev\n")
      assert File.exists?(legacy)

      log = ExUnit.CaptureLog.capture_log(fn -> Bootstrap.run() end)

      refute File.exists?(legacy)
      assert log =~ "deleted legacy"
      assert log =~ legacy
    end

    test "missing workspaces.yaml is a silent no-op", %{runtime_home: runtime_home} do
      legacy = Path.join(runtime_home, "workspaces.yaml")
      refute File.exists?(legacy)
      assert :ok = Bootstrap.run()
      refute File.exists?(legacy)
    end
  end

  describe "ensure_default_workspace" do
    test "default workspace exists after Bootstrap" do
      # The application's Bootstrap ran at boot, so "default" should already
      # be in the Registry. Confirm it survives explicit re-invocation.
      assert :ok = Bootstrap.run()

      {:ok, id} =
        Esr.Resource.Workspace.NameIndex.id_for_name(:esr_workspace_name_index, "default")

      assert {:ok, ws} = Registry.get_by_id(id)
      assert ws.name == "default"
    end

    test "is idempotent — running twice doesn't error or duplicate" do
      assert :ok = Bootstrap.run()
      {:ok, id1} =
        Esr.Resource.Workspace.NameIndex.id_for_name(:esr_workspace_name_index, "default")

      assert :ok = Bootstrap.run()
      {:ok, id2} =
        Esr.Resource.Workspace.NameIndex.id_for_name(:esr_workspace_name_index, "default")

      # Same UUID — second run was a no-op
      assert id1 == id2
    end

    test "both: deletes legacy yaml + leaves default workspace intact",
         %{runtime_home: runtime_home} do
      File.write!(Path.join(runtime_home, "workspaces.yaml"), "stale: yes")

      assert :ok = Bootstrap.run()

      refute File.exists?(Path.join(runtime_home, "workspaces.yaml"))

      {:ok, id} =
        Esr.Resource.Workspace.NameIndex.id_for_name(:esr_workspace_name_index, "default")

      assert {:ok, _} = Registry.get_by_id(id)
    end
  end
end

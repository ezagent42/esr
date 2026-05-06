defmodule Esr.ApplicationFirstBootTest do
  use ExUnit.Case, async: false

  alias Esr.Resource.Workspace.{Bootstrap, Registry, NameIndex}

  setup do
    # tmp is used as ESRD_HOME; runtime_home = tmp/default (ESR_INSTANCE defaults to "default")
    tmp = Path.join(System.tmp_dir!(), "esr-firstboot-#{:erlang.unique_integer([:positive])}")
    runtime_home = Path.join(tmp, "default")
    File.mkdir_p!(runtime_home)

    # Snapshot + restore ESRD_HOME env
    prev_esrd_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    # Start fresh NameIndex + Registry
    {:ok, _} = start_supervised({NameIndex, []})
    {:ok, _} = start_supervised(Registry)

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
    test "creates default workspace if missing", %{tmp: _tmp} do
      assert :error = Registry.get("default")
      assert :ok = Bootstrap.run()
      assert {:ok, ws} = Registry.get("default")
      assert ws.name == "default"
    end

    test "is idempotent — running twice doesn't error or duplicate", %{tmp: _tmp} do
      assert :ok = Bootstrap.run()
      assert {:ok, ws1} = Registry.get("default")

      assert :ok = Bootstrap.run()
      assert {:ok, ws2} = Registry.get("default")

      # Same name — second run was a no-op
      assert ws1.name == ws2.name
    end

    test "both: deletes legacy + creates default in one run", %{runtime_home: runtime_home} do
      File.write!(Path.join(runtime_home, "workspaces.yaml"), "stale: yes")

      assert :ok = Bootstrap.run()

      refute File.exists?(Path.join(runtime_home, "workspaces.yaml"))
      assert {:ok, _} = Registry.get("default")
    end
  end
end

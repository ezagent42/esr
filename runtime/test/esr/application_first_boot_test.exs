defmodule Esr.ApplicationFirstBootTest do
  use ExUnit.Case, async: false

  alias Esr.Resource.Workspace.Bootstrap

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

  describe "bootstrap user-default workspace" do
    setup do
      # Seed a known user so Bootstrap can resolve the env id
      Esr.Test.UserFixture.load_snapshot(
        %{
          "bootstrapper" => %Esr.Entity.User.Struct{
            username: "bootstrapper",
            feishu_ids: ["ou_boot"]
          }
        },
        %{"bootstrapper" => "bootstrapper-uuid"}
      )

      System.put_env("ESR_BOOTSTRAP_PRINCIPAL_ID", "ou_boot")
      on_exit(fn -> System.delete_env("ESR_BOOTSTRAP_PRINCIPAL_ID") end)
      :ok
    end

    test "Bootstrap creates <user>-default + links it" do
      assert :ok = Bootstrap.run()

      {:ok, id} =
        Esr.Uri.Compat.uuid_for_workspace_name("bootstrapper-default"
        )

      assert {:ok, ws} = Esr.Uri.Compat.workspace_by_uuid(id)
      assert ws.name == "bootstrapper-default"

      assert {:ok, ^id} =
               Esr.Uri.Compat.default_workspace_for_user_name("bootstrapper")
    end

    test "is idempotent — running twice does not create a second workspace" do
      assert :ok = Bootstrap.run()
      {:ok, id1} =
        Esr.Uri.Compat.uuid_for_workspace_name("bootstrapper-default"
        )

      assert :ok = Bootstrap.run()
      {:ok, id2} =
        Esr.Uri.Compat.uuid_for_workspace_name("bootstrapper-default"
        )

      assert id1 == id2
    end

    test "deletes legacy yaml + leaves bootstrap workspace intact",
         %{runtime_home: runtime_home} do
      File.write!(Path.join(runtime_home, "workspaces.yaml"), "stale: yes")

      assert :ok = Bootstrap.run()

      refute File.exists?(Path.join(runtime_home, "workspaces.yaml"))

      {:ok, id} =
        Esr.Uri.Compat.uuid_for_workspace_name("bootstrapper-default"
        )

      assert {:ok, _} = Esr.Uri.Compat.workspace_by_uuid(id)
    end
  end
end

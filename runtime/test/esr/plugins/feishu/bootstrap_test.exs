defmodule Esr.Plugins.Feishu.BootstrapTest do
  @moduledoc """
  PR-9 T10: `Esr.Plugins.Feishu.Bootstrap.bootstrap/1` reads
  `adapters.yaml` and spawns a `FeishuAppAdapter` peer per `type: feishu`
  instance, registered under `:feishu_app_adapter_<instance_id>` in
  Scope.Admin.Process so `EsrWeb.AdapterChannel.forward_to_new_chain/2`
  can route inbound frames.

  Before T10 the peer was never spawned at boot — `restore_adapters_from_disk`
  only launched the Python sidecar; the Elixir counterpart was absent
  and every inbound frame logged "no FeishuAppAdapter for app_id=...".
  """
  use ExUnit.Case, async: false

  setup do
    assert is_pid(Process.whereis(Esr.Scope.Admin.Process))
    assert is_pid(Process.whereis(Esr.Scope.Admin.ChildrenSupervisor))

    tmp = Path.join(System.tmp_dir!(), "adapters-#{System.unique_integer([:positive])}.yaml")

    on_exit(fn ->
      File.rm(tmp)

      for name <- [
            :feishu_app_adapter_main_bot,
            :feishu_app_adapter_secondary,
            :feishu_app_adapter_only
          ] do
        case Esr.Scope.Admin.Process.admin_peer(name) do
          {:ok, pid} ->
            DynamicSupervisor.terminate_child(
              Esr.Scope.Admin.ChildrenSupervisor,
              pid
            )

          _ ->
            :ok
        end
      end
    end)

    {:ok, tmp: tmp}
  end

  test "registers one FeishuAppAdapter per feishu-type instance in adapters.yaml",
       %{tmp: tmp} do
    File.write!(tmp, """
    instances:
      main_bot:
        type: feishu
        config:
          app_id: cli_a9563cc03d399cc9
          app_secret: sec1
      secondary:
        type: feishu
        config:
          app_id: cli_secondary_bot
          app_secret: sec2
      cc_mcp_one:
        type: cc_mcp
        config: {}
    """)

    assert :ok = Esr.Plugins.Feishu.Bootstrap.bootstrap(tmp)

    {:ok, main_pid} = Esr.Scope.Admin.Process.admin_peer(:feishu_app_adapter_main_bot)
    {:ok, secondary_pid} = Esr.Scope.Admin.Process.admin_peer(:feishu_app_adapter_secondary)
    assert Process.alive?(main_pid)
    assert Process.alive?(secondary_pid)

    # Feishu-platform app_id is retained in state (used for outbound
    # REST calls) even though registration is keyed by instance_id.
    assert %{instance_id: "main_bot", app_id: "cli_a9563cc03d399cc9"} =
             :sys.get_state(main_pid)

    # Non-feishu instances are skipped by this bootstrap path.
    assert :error = Esr.Scope.Admin.Process.admin_peer(:feishu_app_adapter_cc_mcp_one)
  end

  test "is idempotent — re-running with the same adapters.yaml is :ok",
       %{tmp: tmp} do
    File.write!(tmp, """
    instances:
      only:
        type: feishu
        config:
          app_id: cli_idempotent
    """)

    assert :ok = Esr.Plugins.Feishu.Bootstrap.bootstrap(tmp)
    {:ok, pid1} = Esr.Scope.Admin.Process.admin_peer(:feishu_app_adapter_only)

    assert :ok = Esr.Plugins.Feishu.Bootstrap.bootstrap(tmp)
    {:ok, pid2} = Esr.Scope.Admin.Process.admin_peer(:feishu_app_adapter_only)

    assert pid1 == pid2, "second call must not spawn a duplicate peer"
  end

  test "missing adapters.yaml → :ok (graceful no-op, matches bootstrap_slash_handler policy)",
       %{tmp: tmp} do
    # File intentionally not created.
    refute File.exists?(tmp)
    assert :ok = Esr.Plugins.Feishu.Bootstrap.bootstrap(tmp)
  end
end

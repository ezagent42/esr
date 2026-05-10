defmodule Esr.Plugins.Feishu.BootstrapTest do
  @moduledoc """
  PR-9 T10 / yaml-layout-v2 (2026-05-09):
  `Esr.Plugins.Feishu.Bootstrap.bootstrap/1` reads the per-thing
  adapter directory layout via `Esr.Adapters.list/1` and spawns a
  `FeishuAppAdapter` peer per `type: feishu` instance, registered under
  `:feishu_app_adapter_<instance_id>` in Scope.Admin.Process so
  `EsrWeb.AdapterChannel.forward_to_new_chain/2` can route inbound
  frames.

  Pre-v2 layout used a monolithic `adapters.yaml`; this test exercises
  the new `adapters/<name>/config.yaml` shape and uses the `:home` opt
  so we never touch the user's `~/.esrd`.
  """
  use ExUnit.Case, async: false

  setup do
    assert is_pid(Process.whereis(Esr.Session.Admin.Process))
    assert is_pid(Process.whereis(Esr.Session.Admin.ChildrenSupervisor))

    home =
      System.tmp_dir!()
      |> Path.join("feishu_bootstrap_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)

    on_exit(fn ->
      File.rm_rf!(home)

      for name <- [
            :feishu_app_adapter_main_bot,
            :feishu_app_adapter_secondary,
            :feishu_app_adapter_only
          ] do
        case Esr.Session.Admin.Process.admin_peer(name) do
          {:ok, pid} ->
            DynamicSupervisor.terminate_child(
              Esr.Session.Admin.ChildrenSupervisor,
              pid
            )

          _ ->
            :ok
        end
      end
    end)

    {:ok, home: home}
  end

  test "registers one FeishuAppAdapter per feishu-type instance under adapters/",
       %{home: home} do
    opts = [home: home]
    :ok = Esr.Adapters.add("main_bot", "feishu", %{"app_id" => "cli_a9563cc03d399cc9", "app_secret" => "sec1"}, opts)
    :ok = Esr.Adapters.add("secondary", "feishu", %{"app_id" => "cli_secondary_bot", "app_secret" => "sec2"}, opts)
    :ok = Esr.Adapters.add("cc_mcp_one", "cc_mcp", %{}, opts)

    assert :ok = Esr.Plugins.Feishu.Bootstrap.bootstrap(opts)

    {:ok, main_pid} = Esr.Session.Admin.Process.admin_peer(:feishu_app_adapter_main_bot)
    {:ok, secondary_pid} = Esr.Session.Admin.Process.admin_peer(:feishu_app_adapter_secondary)
    assert Process.alive?(main_pid)
    assert Process.alive?(secondary_pid)

    # Feishu-platform app_id is retained in state (used for outbound
    # REST calls) even though registration is keyed by instance_id.
    assert %{instance_id: "main_bot", app_id: "cli_a9563cc03d399cc9"} =
             :sys.get_state(main_pid)

    # Non-feishu instances are skipped by this bootstrap path.
    assert :error = Esr.Session.Admin.Process.admin_peer(:feishu_app_adapter_cc_mcp_one)
  end

  test "is idempotent — re-running with the same adapters/ tree is :ok",
       %{home: home} do
    opts = [home: home]
    :ok = Esr.Adapters.add("only", "feishu", %{"app_id" => "cli_idempotent"}, opts)

    assert :ok = Esr.Plugins.Feishu.Bootstrap.bootstrap(opts)
    {:ok, pid1} = Esr.Session.Admin.Process.admin_peer(:feishu_app_adapter_only)

    assert :ok = Esr.Plugins.Feishu.Bootstrap.bootstrap(opts)
    {:ok, pid2} = Esr.Session.Admin.Process.admin_peer(:feishu_app_adapter_only)

    assert pid1 == pid2, "second call must not spawn a duplicate peer"
  end

  test "empty adapters tree → :ok (graceful no-op, matches bootstrap_slash_handler policy)",
       %{home: home} do
    # No adapters/ created — Esr.Adapters.list/1 returns [] cleanly.
    refute File.exists?(Path.join(home, "adapters"))
    assert :ok = Esr.Plugins.Feishu.Bootstrap.bootstrap(home: home)
  end
end

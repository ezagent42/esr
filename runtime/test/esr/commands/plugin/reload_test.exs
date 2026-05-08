defmodule Esr.Commands.Plugin.ReloadTest do
  @moduledoc """
  Tests for `Esr.Commands.Plugin.Reload`.

  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §4, §10.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Esr.Commands.Plugin.Reload
  alias Esr.Plugin.ConfigSnapshot

  # Ensure ConfigSnapshot table exists for all tests.
  setup_all do
    ConfigSnapshot.create_table()
    :ok
  end

  # ------------------------------------------------------------------
  # Stub modules for testing plugin module resolution.
  # ------------------------------------------------------------------

  # A hot-reloadable stub that succeeds.
  defmodule StubPlugin.OkPlugin do
    @behaviour Esr.Plugin.Behaviour
    @impl Esr.Plugin.Behaviour
    def on_config_change(_changed_keys), do: :ok
  end

  # A stub that returns an error.
  defmodule StubPlugin.ErrorPlugin do
    @behaviour Esr.Plugin.Behaviour
    @impl Esr.Plugin.Behaviour
    def on_config_change(_changed_keys), do: {:error, :simulated_failure}
  end

  # A stub that raises an exception.
  defmodule StubPlugin.RaisingPlugin do
    @behaviour Esr.Plugin.Behaviour
    @impl Esr.Plugin.Behaviour
    def on_config_change(_changed_keys), do: raise("boom")
  end

  # A stub that sleeps longer than the 5-second timeout.
  defmodule StubPlugin.SlowPlugin do
    @behaviour Esr.Plugin.Behaviour
    @impl Esr.Plugin.Behaviour
    def on_config_change(_changed_keys) do
      Process.sleep(10_000)
      :ok
    end
  end

  # A module without on_config_change (not implementing the behaviour).
  defmodule StubPlugin.NoBehaviourPlugin do
    def some_other_function, do: :ok
  end

  # ------------------------------------------------------------------
  # Error path: unknown plugin
  # ------------------------------------------------------------------

  describe "unknown plugin" do
    test "returns {:error, %{type: unknown_plugin}} for non-existent plugin" do
      cmd = %{"args" => %{"plugin" => "nonexistent_plugin_xyz_999"}}

      assert {:error, %{"type" => "unknown_plugin", "plugin" => "nonexistent_plugin_xyz_999"}} =
               Reload.execute(cmd)
    end
  end

  # ------------------------------------------------------------------
  # Error path: not_hot_reloadable
  # ------------------------------------------------------------------

  describe "not_hot_reloadable" do
    test "returns {:error, %{type: not_hot_reloadable}} for plugin without flag" do
      tmp_dir = System.tmp_dir!() |> Path.join("reload_test_#{:rand.uniform(99_999)}")
      plugin_dir = Path.join(tmp_dir, "cold_plugin")
      File.mkdir_p!(plugin_dir)
      manifest_path = Path.join(plugin_dir, "manifest.yaml")

      File.write!(manifest_path, """
      name: cold_plugin
      version: 0.1.0
      description: test
      depends_on:
        core: ">= 0.1.0"
        plugins: []
      declares: {}
      hot_reloadable: false
      """)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      cmd = %{"args" => %{"plugin" => "cold_plugin", "_plugin_root_override" => tmp_dir}}

      assert {:error, %{"type" => "not_hot_reloadable", "plugin" => "cold_plugin"}} =
               Reload.execute(cmd)
    end
  end

  # ------------------------------------------------------------------
  # Error path: plugin module not found on disk
  # ------------------------------------------------------------------

  describe "plugin_module_not_found" do
    test "returns {:error, %{type: plugin_module_not_found}} when module is not loaded" do
      tmp_dir = System.tmp_dir!() |> Path.join("reload_test_#{:rand.uniform(99_999)}")
      plugin_dir = Path.join(tmp_dir, "stub_no_cb")
      File.mkdir_p!(plugin_dir)

      File.write!(Path.join(plugin_dir, "manifest.yaml"), """
      name: stub_no_cb
      version: 0.1.0
      description: test
      depends_on:
        core: ">= 0.1.0"
        plugins: []
      declares: {}
      hot_reloadable: true
      """)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      # Convention: stub_no_cb → Esr.Plugins.StubNoCb.Plugin
      # That module is not compiled so Code.ensure_loaded? returns false.
      cmd = %{"args" => %{"plugin" => "stub_no_cb", "_plugin_root_override" => tmp_dir}}

      assert {:error, %{"type" => "plugin_module_not_found"}} = Reload.execute(cmd)
    end
  end

  # ------------------------------------------------------------------
  # Happy path — callback returns :ok
  # invoke_callback/3 is exposed as public for test-seam access.
  # ------------------------------------------------------------------

  describe "happy path — callback returns :ok" do
    test "returns {:ok, reloaded: true, changed_keys} and updates ConfigSnapshot" do
      ConfigSnapshot.init("ok_plugin", %{"http_proxy" => "old_value"})

      result =
        Reload.invoke_callback(
          Esr.Commands.Plugin.ReloadTest.StubPlugin.OkPlugin,
          "ok_plugin",
          ["http_proxy"]
        )

      assert {:ok, %{"reloaded" => true, "changed_keys" => ["http_proxy"], "plugin" => "ok_plugin"}} =
               result

      # After success, ConfigSnapshot.update/1 is called (resolves to %{} when no yaml on disk).
      assert %{} == ConfigSnapshot.get("ok_plugin")
    end
  end

  describe "force reload — empty changed_keys" do
    test "callback fires with [] and returns reloaded: true" do
      ConfigSnapshot.init("ok_plugin_force", %{})

      result =
        Reload.invoke_callback(
          Esr.Commands.Plugin.ReloadTest.StubPlugin.OkPlugin,
          "ok_plugin_force",
          []
        )

      assert {:ok, %{"reloaded" => true, "changed_keys" => []}} = result
    end
  end

  # ------------------------------------------------------------------
  # Callback returns {:error, reason} → fallback_active: true
  # ------------------------------------------------------------------

  describe "callback returns {:error, reason}" do
    test "returns reloaded: false + fallback_active: true + logs warning" do
      ConfigSnapshot.init("err_plugin", %{"k" => "v"})

      log =
        capture_log(fn ->
          result =
            Reload.invoke_callback(
              Esr.Commands.Plugin.ReloadTest.StubPlugin.ErrorPlugin,
              "err_plugin",
              ["k"]
            )

          assert {:ok,
                  %{
                    "reloaded" => false,
                    "fallback_active" => true,
                    "plugin" => "err_plugin",
                    "changed_keys" => ["k"]
                  }} = result
        end)

      assert log =~ "failed to apply config change"
    end

    test "snapshot is NOT updated on callback error" do
      ConfigSnapshot.init("err_plugin2", %{"k" => "old"})

      Reload.invoke_callback(
        Esr.Commands.Plugin.ReloadTest.StubPlugin.ErrorPlugin,
        "err_plugin2",
        ["k"]
      )

      # Snapshot must remain at the init value (not updated).
      assert %{"k" => "old"} == ConfigSnapshot.get("err_plugin2")
    end
  end

  # ------------------------------------------------------------------
  # Callback raises an exception → caught by safe_call/2 → fallback
  # ------------------------------------------------------------------

  describe "callback raises an exception" do
    test "exception is caught; returns fallback_active: true" do
      ConfigSnapshot.init("raising_plugin", %{})

      log =
        capture_log(fn ->
          result =
            Reload.invoke_callback(
              Esr.Commands.Plugin.ReloadTest.StubPlugin.RaisingPlugin,
              "raising_plugin",
              []
            )

          assert {:ok, %{"reloaded" => false, "fallback_active" => true}} = result
        end)

      # Should log a warning (either "failed to apply" or "timed out")
      assert log =~ ~r/failed to apply|timed out/
    end
  end

  # ------------------------------------------------------------------
  # Callback timeout (5 s) — spec §9 Risk 1
  # ------------------------------------------------------------------

  describe "callback timeout (5 s)" do
    @tag timeout: 15_000
    test "returns reason: callback_timeout when callback exceeds 5 s" do
      ConfigSnapshot.init("slow_plugin", %{})

      log =
        capture_log(fn ->
          result =
            Reload.invoke_callback(
              Esr.Commands.Plugin.ReloadTest.StubPlugin.SlowPlugin,
              "slow_plugin",
              []
            )

          assert {:ok,
                  %{
                    "reloaded" => false,
                    "fallback_active" => true,
                    "reason" => "callback_timeout"
                  }} = result
        end)

      assert log =~ "timed out"
    end
  end
end

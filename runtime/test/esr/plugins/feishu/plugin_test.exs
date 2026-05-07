defmodule Esr.Plugins.Feishu.PluginTest do
  @moduledoc """
  Tests for `Esr.Plugins.Feishu.Plugin.on_config_change/1`.

  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §8 HR-3 + §10.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Esr.Plugins.Feishu.Plugin

  describe "on_config_change/1" do
    test "returns :ok for app_id change (no log)" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["app_id"])
      end)

      assert log == ""
    end

    test "returns :ok for app_secret change (no log)" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["app_secret"])
      end)

      assert log == ""
    end

    test "returns :ok for log_level change AND logs a warning" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["log_level"])
      end)

      assert log =~ "log_level"
      assert log =~ ~r/warn|warning/i
    end

    test "returns :ok when changed_keys has both app_id and log_level" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["app_id", "log_level"])
      end)

      # Only the log_level warning should appear.
      assert log =~ "log_level"
      refute log =~ "app_id"
    end

    test "returns :ok for empty changed_keys (force reload, no log)" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change([])
      end)

      assert log == ""
    end
  end
end

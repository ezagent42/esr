defmodule Esr.Plugins.ClaudeCode.PluginTest do
  @moduledoc """
  Tests for `Esr.Plugins.ClaudeCode.Plugin.on_config_change/1`.

  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §8 HR-3 + §10.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Esr.Plugins.ClaudeCode.Plugin

  describe "on_config_change/1" do
    test "returns :ok for proxy key change (no log)" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["http_proxy"])
      end)

      assert log == ""
    end

    test "returns :ok for https_proxy change (no log)" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["https_proxy"])
      end)

      assert log == ""
    end

    test "returns :ok for no_proxy change (no log)" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["no_proxy"])
      end)

      assert log == ""
    end

    test "returns :ok for esrd_url change (no log)" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["esrd_url"])
      end)

      assert log == ""
    end

    test "returns :ok for anthropic_api_key_ref change AND logs a warning" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["anthropic_api_key_ref"])
      end)

      assert log =~ "anthropic_api_key_ref"
      assert log =~ ~r/warn|warning/i
    end

    test "returns :ok when changed_keys includes both a proxy key and anthropic_api_key_ref" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change(["http_proxy", "anthropic_api_key_ref"])
      end)

      # Only the api_key warning should appear.
      assert log =~ "anthropic_api_key_ref"
    end

    test "returns :ok for empty changed_keys (force reload, no log)" do
      log = capture_log(fn ->
        assert :ok == Plugin.on_config_change([])
      end)

      assert log == ""
    end
  end
end

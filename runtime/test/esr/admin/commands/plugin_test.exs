defmodule Esr.Admin.Commands.PluginTest do
  @moduledoc """
  Smoke tests for the 5 `/plugin {list,info,install,enable,disable}`
  command modules (Track 0 Task 0.6). Each test isolates state via tmp
  dirs + ESRD_HOME / ESR_INSTANCE env vars so concurrent suites don't
  collide on the canonical plugins.yaml path.
  """
  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Plugin

  @tmp Path.join(System.tmp_dir!(), "esr_plugin_cmd_test")

  setup do
    File.rm_rf!(@tmp)
    File.mkdir_p!(Path.join(@tmp, "default"))

    prev_home = System.get_env("ESRD_HOME")
    prev_inst = System.get_env("ESR_INSTANCE")
    System.put_env("ESRD_HOME", @tmp)
    System.put_env("ESR_INSTANCE", "default")

    on_exit(fn ->
      File.rm_rf!(@tmp)
      restore_env("ESRD_HOME", prev_home)
      restore_env("ESR_INSTANCE", prev_inst)
    end)

    :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp write_plugins_yaml!(content) do
    File.write!(Path.join([@tmp, "default", "plugins.yaml"]), content)
  end

  describe "List" do
    test "no plugins discovered → friendly message" do
      # `Plugin.Loader.discover/0` walks the canonical plugins root
      # which (in this worktree) contains nothing yet — so this exercises
      # the "empty result" branch.
      {:ok, %{"text" => text}} = Plugin.List.execute(%{})
      assert text =~ "no plugins installed" or text =~ "installed plugins:"
    end
  end

  describe "Info" do
    test "missing plugin returns clear error" do
      {:ok, %{"text" => text}} =
        Plugin.Info.execute(%{"args" => %{"name" => "ghost"}})

      assert text =~ "plugin not found: ghost"
    end
  end

  describe "Enable" do
    test "empty name → usage hint" do
      {:ok, %{"text" => text}} = Plugin.Enable.execute(%{"args" => %{"name" => ""}})
      assert text =~ "usage:"
    end

    test "non-existent plugin is rejected with helpful hint" do
      {:ok, %{"text" => text}} =
        Plugin.Enable.execute(%{"args" => %{"name" => "ghost"}})

      assert text =~ "plugin not installed: ghost"
    end
  end

  describe "Disable" do
    test "empty name → usage hint" do
      {:ok, %{"text" => text}} =
        Plugin.Disable.execute(%{"args" => %{"name" => ""}})

      assert text =~ "usage:"
    end

    test "writes plugins.yaml without the named plugin" do
      write_plugins_yaml!("enabled:\n  - feishu\n  - voice\n")

      {:ok, %{"text" => text}} =
        Plugin.Disable.execute(%{"args" => %{"name" => "feishu"}})

      assert text =~ "disabled plugin: feishu"
      assert Esr.Plugin.PluginsYaml.read() == ["voice"]
    end
  end

  describe "Install" do
    test "missing source path is rejected" do
      {:ok, %{"text" => text}} =
        Plugin.Install.execute(%{"args" => %{"source" => "/nonexistent/path"}})

      assert text =~ "source not found"
    end

    test "directory without manifest.yaml is rejected" do
      empty = Path.join(@tmp, "empty_src")
      File.mkdir_p!(empty)

      {:ok, %{"text" => text}} =
        Plugin.Install.execute(%{"args" => %{"source" => empty}})

      assert text =~ "no manifest.yaml"
    end

    test "empty source argument → usage hint" do
      {:ok, %{"text" => text}} = Plugin.Install.execute(%{"args" => %{"source" => ""}})
      assert text =~ "usage:"
    end
  end

  describe "PluginsYaml round-trip" do
    test "enable then disable returns to []" do
      :ok = Esr.Plugin.PluginsYaml.enable("feishu")
      assert Esr.Plugin.PluginsYaml.read() == ["feishu"]

      :ok = Esr.Plugin.PluginsYaml.disable("feishu")
      assert Esr.Plugin.PluginsYaml.read() == []
    end

    test "enable is idempotent" do
      :ok = Esr.Plugin.PluginsYaml.enable("voice")
      :ok = Esr.Plugin.PluginsYaml.enable("voice")
      assert Esr.Plugin.PluginsYaml.read() == ["voice"]
    end
  end
end

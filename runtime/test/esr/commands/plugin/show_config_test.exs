defmodule Esr.Commands.Plugin.ShowConfigTest do
  use ExUnit.Case, async: true

  alias Esr.Commands.Plugin.ShowConfig

  setup do
    dir = System.tmp_dir!() |> Path.join("show_config_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)
    global_yaml = Path.join(dir, "plugins.yaml")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{global_yaml: global_yaml}
  end

  test "returns (empty) text when no config is set", ctx do
    cmd = %{
      "kind" => "plugin_show_config",
      "args" => %{
        "plugin" => "my-plugin",
        "_global_path_override" => ctx.global_yaml
      }
    }

    assert {:ok, %{"text" => text}} = ShowConfig.execute(cmd)
    assert String.contains?(text, "empty")
  end

  test "returns config keys when values are set", ctx do
    File.write!(ctx.global_yaml, """
    config:
      my-plugin:
        log_level: "debug"
    """)

    cmd = %{
      "kind" => "plugin_show_config",
      "args" => %{
        "plugin" => "my-plugin",
        "_global_path_override" => ctx.global_yaml
      }
    }

    assert {:ok, %{"text" => text}} = ShowConfig.execute(cmd)
    assert String.contains?(text, "log_level")
    assert String.contains?(text, "debug")
  end

  test "layer=global filters to global layer only", ctx do
    File.write!(ctx.global_yaml, """
    config:
      my-plugin:
        log_level: "info"
    """)

    cmd = %{
      "kind" => "plugin_show_config",
      "args" => %{
        "plugin" => "my-plugin",
        "layer" => "global",
        "_global_path_override" => ctx.global_yaml
      }
    }

    assert {:ok, %{"text" => text}} = ShowConfig.execute(cmd)
    assert String.contains?(text, "[global]")
  end
end

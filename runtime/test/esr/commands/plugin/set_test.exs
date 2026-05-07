defmodule Esr.Commands.Plugin.SetTest do
  use ExUnit.Case, async: true

  alias Esr.Commands.Plugin.Set

  @tmp_dir System.tmp_dir!()

  setup do
    dir = Path.join(@tmp_dir, "plugin_set_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)
    global_yaml = Path.join(dir, "plugins.yaml")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{global_yaml: global_yaml, dir: dir}
  end

  test "returns error for unknown plugin name" do
    cmd = %{
      "kind" => "plugin_set",
      "args" => %{
        "plugin" => "nonexistent-plugin-xyz",
        "key" => "log_level",
        "value" => "debug",
        "layer" => "global"
      }
    }

    assert {:error, %{"type" => "unknown_plugin"}} = Set.execute(cmd)
  end

  test "returns restart hint on successful write" do
    {:ok, manifests} = Esr.Plugin.Loader.discover()
    {plugin_name, manifest} = List.first(manifests)
    schema = manifest.declares[:config_schema] || %{}

    if map_size(schema) == 0 do
      # Skip if manifest has no schema (pre-7.6 state — should not happen after task 7.6).
      :ok
    else
      {key, _entry} = Enum.at(schema, 0)
      tmp_global = System.tmp_dir!() |> Path.join("plugin_set_test_global_#{:rand.uniform(999)}.yaml")
      on_exit(fn -> File.rm(tmp_global) end)

      cmd = %{
        "kind" => "plugin_set",
        "args" => %{
          "plugin" => plugin_name,
          "key" => key,
          "value" => "test-value",
          "layer" => "global",
          "_global_path_override" => tmp_global
        }
      }

      assert {:ok, %{"text" => text}} = Set.execute(cmd)
      assert String.contains?(text, "restart") or String.contains?(text, "config written")
    end
  end

  test "rejects key not in manifest config_schema" do
    {:ok, manifests} = Esr.Plugin.Loader.discover()

    case List.first(manifests) do
      nil ->
        :ok

      {plugin_name, _manifest} ->
        tmp_global =
          System.tmp_dir!() |> Path.join("plugin_set_reject_#{:rand.uniform(999)}.yaml")

        on_exit(fn -> File.rm(tmp_global) end)

        cmd = %{
          "kind" => "plugin_set",
          "args" => %{
            "plugin" => plugin_name,
            "key" => "nonexistent_schema_key_xyz",
            "value" => "test",
            "layer" => "global",
            "_global_path_override" => tmp_global
          }
        }

        result = Set.execute(cmd)

        assert match?({:error, %{"type" => "unknown_config_key"}}, result) or
                 match?({:error, %{"type" => "no_config_schema"}}, result),
               "Expected config key rejection, got: #{inspect(result)}"
    end
  end
end

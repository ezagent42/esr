defmodule Esr.Commands.Plugin.UnsetTest do
  use ExUnit.Case, async: true

  alias Esr.Commands.Plugin.Unset

  test "returns error for unknown plugin name" do
    cmd = %{
      "kind" => "plugin_unset",
      "args" => %{
        "plugin" => "nonexistent-plugin-xyz",
        "key" => "log_level",
        "layer" => "global"
      }
    }

    assert {:error, %{"type" => "unknown_plugin"}} = Unset.execute(cmd)
  end

  test "unset key from known plugin returns success text" do
    {:ok, manifests} = Esr.Plugin.Loader.discover()

    case List.first(manifests) do
      nil ->
        :ok

      {plugin_name, _manifest} ->
        tmp_global =
          System.tmp_dir!() |> Path.join("plugin_unset_test_#{:rand.uniform(999)}.yaml")

        on_exit(fn -> File.rm(tmp_global) end)

        cmd = %{
          "kind" => "plugin_unset",
          "args" => %{
            "plugin" => plugin_name,
            "key" => "any_key",
            "layer" => "global",
            "_global_path_override" => tmp_global
          }
        }

        assert {:ok, %{"text" => text}} = Unset.execute(cmd)
        assert String.contains?(text, "restart")
    end
  end

  test "returns error for invalid layer" do
    {:ok, manifests} = Esr.Plugin.Loader.discover()

    case List.first(manifests) do
      nil ->
        :ok

      {plugin_name, _manifest} ->
        cmd = %{
          "kind" => "plugin_unset",
          "args" => %{
            "plugin" => plugin_name,
            "key" => "any_key",
            "layer" => "bad_layer"
          }
        }

        assert {:error, %{"type" => "invalid_layer"}} = Unset.execute(cmd)
    end
  end
end

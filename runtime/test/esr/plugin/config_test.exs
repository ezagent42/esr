defmodule Esr.Plugin.ConfigTest do
  @moduledoc """
  Per yaml-layout-v2 (spec § 4.1): `Esr.Plugin.Config`'s public API
  names are unchanged, but the `:global_path / :user_path /
  :workspace_path` opts now point at per-plugin directories
  (`plugins/<name>/`) holding `config.yaml` — not the monolithic
  `plugins.yaml :config` map of v1.
  """

  use ExUnit.Case, async: true

  alias Esr.Plugin.Config

  # Each layer is a per-plugin directory containing config.yaml.
  setup do
    tmp =
      System.tmp_dir!() |> Path.join("esr_config_test_#{:rand.uniform(999_999)}")

    File.mkdir_p!(tmp)

    plugin_name = "my-plugin"
    global_dir = Path.join([tmp, "instance", "plugins", plugin_name])
    user_uuid = "aabbccdd-1234-5678-abcd-ef0123456789"
    user_dir = Path.join([tmp, "instance", "users", user_uuid, ".esr", "plugins", plugin_name])
    workspace_dir = Path.join([tmp, "workspace1", ".esr", "plugins", plugin_name])

    File.mkdir_p!(global_dir)
    File.mkdir_p!(user_dir)
    File.mkdir_p!(workspace_dir)

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{
      tmp: tmp,
      plugin_name: plugin_name,
      global_dir: global_dir,
      user_dir: user_dir,
      workspace_dir: workspace_dir,
      user_uuid: user_uuid
    }
  end

  defp write_config(dir, content),
    do: File.write!(Path.join(dir, "config.yaml"), content)

  describe "resolve/2 — 3-layer merge" do
    test "empty all layers returns empty map", ctx do
      result = Config.resolve(ctx.plugin_name, global_path: ctx.global_dir)
      assert result == %{}
    end

    test "global-only: returns global config", ctx do
      write_config(ctx.global_dir, """
      api_key: "global-key"
      log_level: "info"
      """)

      result = Config.resolve(ctx.plugin_name, global_path: ctx.global_dir)
      assert result["api_key"] == "global-key"
      assert result["log_level"] == "info"
    end

    test "user overrides global per-key", ctx do
      write_config(ctx.global_dir, """
      api_key: "global-key"
      log_level: "info"
      """)

      write_config(ctx.user_dir, """
      log_level: "debug"
      """)

      result =
        Config.resolve(ctx.plugin_name,
          global_path: ctx.global_dir,
          user_path: ctx.user_dir
        )

      assert result["api_key"] == "global-key"
      assert result["log_level"] == "debug"
    end

    test "workspace overrides user and global per-key", ctx do
      write_config(ctx.global_dir, """
      http_proxy: "http://global-proxy:8080"
      log_level: "info"
      """)

      write_config(ctx.user_dir, """
      log_level: "debug"
      """)

      write_config(ctx.workspace_dir, """
      http_proxy: ""
      """)

      result =
        Config.resolve(ctx.plugin_name,
          global_path: ctx.global_dir,
          user_path: ctx.user_dir,
          workspace_path: ctx.workspace_dir
        )

      assert result["http_proxy"] == ""
      assert result["log_level"] == "debug"
    end

    test "explicit empty string in workspace layer wins (disables proxy)", ctx do
      write_config(ctx.global_dir, """
      http_proxy: "http://proxy:8080"
      """)

      write_config(ctx.workspace_dir, """
      http_proxy: ""
      """)

      result =
        Config.resolve(ctx.plugin_name,
          global_path: ctx.global_dir,
          workspace_path: ctx.workspace_dir
        )

      assert result["http_proxy"] == ""
    end

    test "absent key in all layers returns nil for get/3", ctx do
      write_config(ctx.global_dir, """
      log_level: "info"
      """)

      assert nil ==
               Config.get(ctx.plugin_name, "nonexistent_key",
                 global_path: ctx.global_dir
               )
    end

    test "get/3 returns most-specific value", ctx do
      write_config(ctx.global_dir, """
      log_level: "info"
      """)

      write_config(ctx.user_dir, """
      log_level: "debug"
      """)

      assert "debug" ==
               Config.get(ctx.plugin_name, "log_level",
                 global_path: ctx.global_dir,
                 user_path: ctx.user_dir
               )
    end

    test "an empty config.yaml file contributes nothing (no error)", ctx do
      write_config(ctx.global_dir, "")
      assert %{} == Config.resolve(ctx.plugin_name, global_path: ctx.global_dir)
    end

    test "missing config.yaml at any layer is treated as empty layer", ctx do
      # ctx.user_dir exists but its config.yaml does not — should not raise.
      write_config(ctx.global_dir, """
      key: global_val
      """)

      assert %{"key" => "global_val"} ==
               Config.resolve(ctx.plugin_name,
                 global_path: ctx.global_dir,
                 user_path: ctx.user_dir
               )
    end

    test "malformed config.yaml at any layer raises (no silent fall-through)", ctx do
      write_config(ctx.global_dir, "not: a: valid: yaml: structure")

      assert_raise RuntimeError, ~r/plugin_config:.*yaml parse error/, fn ->
        Config.resolve(ctx.plugin_name, global_path: ctx.global_dir)
      end
    end
  end

  describe "store_layer/4 — atomic write" do
    test "writes key to global layer", ctx do
      Config.store_layer(ctx.plugin_name, "log_level", "debug",
        layer: :global,
        global_path: ctx.global_dir
      )

      result = Config.resolve(ctx.plugin_name, global_path: ctx.global_dir)
      assert result["log_level"] == "debug"
    end

    test "write-then-read round-trip at workspace layer", ctx do
      Config.store_layer(ctx.plugin_name, "http_proxy", "http://test:8080",
        layer: :workspace,
        workspace_path: ctx.workspace_dir
      )

      result = Config.resolve(ctx.plugin_name, workspace_path: ctx.workspace_dir)
      assert result["http_proxy"] == "http://test:8080"
    end

    test "store is idempotent (overwrite same key)", ctx do
      Config.store_layer(ctx.plugin_name, "k", "v1",
        layer: :global,
        global_path: ctx.global_dir
      )

      Config.store_layer(ctx.plugin_name, "k", "v2",
        layer: :global,
        global_path: ctx.global_dir
      )

      result = Config.resolve(ctx.plugin_name, global_path: ctx.global_dir)
      assert result["k"] == "v2"
    end

    test "store creates the per-plugin directory if missing", ctx do
      # Write to a nested dir that does not yet exist.
      missing_dir = Path.join(ctx.tmp, "nonexistent/plugins/x")
      refute File.exists?(missing_dir)

      Config.store_layer(ctx.plugin_name, "k", "v",
        layer: :global,
        global_path: missing_dir
      )

      assert File.exists?(Path.join(missing_dir, "config.yaml"))
    end
  end

  describe "delete_layer/3 — remove key from layer" do
    test "deletes a key from the global layer", ctx do
      write_config(ctx.global_dir, """
      log_level: "info"
      api_key: "key"
      """)

      Config.delete_layer(ctx.plugin_name, "log_level",
        layer: :global,
        global_path: ctx.global_dir
      )

      result = Config.resolve(ctx.plugin_name, global_path: ctx.global_dir)
      refute Map.has_key?(result, "log_level")
      assert result["api_key"] == "key"
    end

    test "deleting nonexistent key is idempotent", ctx do
      write_config(ctx.global_dir, """
      log_level: "info"
      """)

      assert :ok =
               Config.delete_layer(ctx.plugin_name, "nonexistent",
                 layer: :global,
                 global_path: ctx.global_dir
               )
    end
  end
end

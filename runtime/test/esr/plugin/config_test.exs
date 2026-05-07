defmodule Esr.Plugin.ConfigTest do
  use ExUnit.Case, async: true

  alias Esr.Plugin.Config

  # We use temp dirs to simulate the layer files.
  setup do
    tmp =
      System.tmp_dir!() |> Path.join("esr_config_test_#{:rand.uniform(999_999)}")

    File.mkdir_p!(tmp)

    global_dir = Path.join(tmp, "instance")
    user_uuid = "aabbccdd-1234-5678-abcd-ef0123456789"
    user_dir = Path.join([tmp, "instance", "users", user_uuid, ".esr"])
    workspace_dir = Path.join([tmp, "workspace1", ".esr"])

    File.mkdir_p!(global_dir)
    File.mkdir_p!(user_dir)
    File.mkdir_p!(workspace_dir)

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{
      tmp: tmp,
      global_plugins_yaml: Path.join(global_dir, "plugins.yaml"),
      user_plugins_yaml: Path.join(user_dir, "plugins.yaml"),
      workspace_plugins_yaml: Path.join(workspace_dir, "plugins.yaml"),
      user_uuid: user_uuid
    }
  end

  defp write_yaml(path, content), do: File.write!(path, content)

  describe "resolve/2 — 3-layer merge" do
    test "empty all layers returns empty map", ctx do
      result = Config.resolve("my-plugin", global_path: ctx.global_plugins_yaml)
      assert result == %{}
    end

    test "global-only: returns global config", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      enabled:
        - my-plugin
      config:
        my-plugin:
          api_key: "global-key"
          log_level: "info"
      """)

      result = Config.resolve("my-plugin", global_path: ctx.global_plugins_yaml)
      assert result["api_key"] == "global-key"
      assert result["log_level"] == "info"
    end

    test "user overrides global per-key", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      config:
        my-plugin:
          api_key: "global-key"
          log_level: "info"
      """)

      write_yaml(ctx.user_plugins_yaml, """
      config:
        my-plugin:
          log_level: "debug"
      """)

      result =
        Config.resolve("my-plugin",
          global_path: ctx.global_plugins_yaml,
          user_path: ctx.user_plugins_yaml
        )

      assert result["api_key"] == "global-key"
      assert result["log_level"] == "debug"
    end

    test "workspace overrides user and global per-key", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      config:
        my-plugin:
          http_proxy: "http://global-proxy:8080"
          log_level: "info"
      """)

      write_yaml(ctx.user_plugins_yaml, """
      config:
        my-plugin:
          log_level: "debug"
      """)

      write_yaml(ctx.workspace_plugins_yaml, """
      config:
        my-plugin:
          http_proxy: ""
      """)

      result =
        Config.resolve("my-plugin",
          global_path: ctx.global_plugins_yaml,
          user_path: ctx.user_plugins_yaml,
          workspace_path: ctx.workspace_plugins_yaml
        )

      assert result["http_proxy"] == ""
      assert result["log_level"] == "debug"
    end

    test "explicit empty string in workspace layer wins (disables proxy)", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      config:
        my-plugin:
          http_proxy: "http://proxy:8080"
      """)

      write_yaml(ctx.workspace_plugins_yaml, """
      config:
        my-plugin:
          http_proxy: ""
      """)

      result =
        Config.resolve("my-plugin",
          global_path: ctx.global_plugins_yaml,
          workspace_path: ctx.workspace_plugins_yaml
        )

      assert result["http_proxy"] == ""
    end

    test "absent key in all layers returns nil for get/3", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      config:
        my-plugin:
          log_level: "info"
      """)

      assert nil ==
               Config.get("my-plugin", "nonexistent_key",
                 global_path: ctx.global_plugins_yaml
               )
    end

    test "get/3 returns most-specific value", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      config:
        my-plugin:
          log_level: "info"
      """)

      write_yaml(ctx.user_plugins_yaml, """
      config:
        my-plugin:
          log_level: "debug"
      """)

      assert "debug" ==
               Config.get("my-plugin", "log_level",
                 global_path: ctx.global_plugins_yaml,
                 user_path: ctx.user_plugins_yaml
               )
    end

    test "other plugin's config in same yaml is not returned", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      config:
        my-plugin:
          log_level: "info"
        other-plugin:
          log_level: "warn"
      """)

      result = Config.resolve("my-plugin", global_path: ctx.global_plugins_yaml)
      refute Map.has_key?(result, "other-plugin")
    end
  end

  describe "store_layer/4 — atomic write" do
    test "writes key to global layer", ctx do
      Config.store_layer("my-plugin", "log_level", "debug",
        layer: :global,
        global_path: ctx.global_plugins_yaml
      )

      result = Config.resolve("my-plugin", global_path: ctx.global_plugins_yaml)
      assert result["log_level"] == "debug"
    end

    test "write-then-read round-trip at workspace layer", ctx do
      Config.store_layer("my-plugin", "http_proxy", "http://test:8080",
        layer: :workspace,
        workspace_path: ctx.workspace_plugins_yaml
      )

      result = Config.resolve("my-plugin", workspace_path: ctx.workspace_plugins_yaml)
      assert result["http_proxy"] == "http://test:8080"
    end

    test "store is idempotent (overwrite same key)", ctx do
      Config.store_layer("my-plugin", "k", "v1",
        layer: :global,
        global_path: ctx.global_plugins_yaml
      )

      Config.store_layer("my-plugin", "k", "v2",
        layer: :global,
        global_path: ctx.global_plugins_yaml
      )

      result = Config.resolve("my-plugin", global_path: ctx.global_plugins_yaml)
      assert result["k"] == "v2"
    end
  end

  describe "delete_layer/3 — remove key from layer" do
    test "deletes a key from the global layer", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      config:
        my-plugin:
          log_level: "info"
          api_key: "key"
      """)

      Config.delete_layer("my-plugin", "log_level",
        layer: :global,
        global_path: ctx.global_plugins_yaml
      )

      result = Config.resolve("my-plugin", global_path: ctx.global_plugins_yaml)
      refute Map.has_key?(result, "log_level")
      assert result["api_key"] == "key"
    end

    test "deleting nonexistent key is idempotent", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      config:
        my-plugin:
          log_level: "info"
      """)

      assert :ok =
               Config.delete_layer("my-plugin", "nonexistent",
                 layer: :global,
                 global_path: ctx.global_plugins_yaml
               )
    end
  end
end

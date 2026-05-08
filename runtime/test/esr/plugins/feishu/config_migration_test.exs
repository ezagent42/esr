defmodule Esr.Plugins.Feishu.ConfigMigrationTest do
  use ExUnit.Case, async: true

  alias Esr.Plugin.Manifest

  @feishu_manifest_path Path.expand(
                          "../../../../lib/esr/plugins/feishu/manifest.yaml",
                          __DIR__
                        )

  @cc_manifest_path Path.expand(
                      "../../../../lib/esr/plugins/claude_code/manifest.yaml",
                      __DIR__
                    )

  describe "feishu manifest config_schema" do
    test "feishu manifest has config_schema with log_level" do
      {:ok, manifest} = Manifest.parse(@feishu_manifest_path)
      schema = manifest.declares[:config_schema] || %{}
      assert Map.has_key?(schema, "log_level"),
             "feishu manifest missing log_level in config_schema"
    end

    test "feishu config_schema entries have required fields" do
      {:ok, manifest} = Manifest.parse(@feishu_manifest_path)
      schema = manifest.declares[:config_schema] || %{}

      Enum.each(schema, fn {key, entry} ->
        assert Map.has_key?(entry, "type"), "feishu config_schema.#{key} missing type"
        assert Map.has_key?(entry, "description"), "feishu config_schema.#{key} missing description"
        assert Map.has_key?(entry, "default"), "feishu config_schema.#{key} missing default"
      end)
    end
  end

  describe "claude_code manifest config_schema" do
    test "claude_code manifest has config_schema with http_proxy" do
      {:ok, manifest} = Manifest.parse(@cc_manifest_path)
      schema = manifest.declares[:config_schema] || %{}

      assert Map.has_key?(schema, "http_proxy"),
             "claude_code manifest missing http_proxy in config_schema"
    end

    test "claude_code manifest has config_schema with anthropic_api_key_ref" do
      {:ok, manifest} = Manifest.parse(@cc_manifest_path)
      schema = manifest.declares[:config_schema] || %{}

      assert Map.has_key?(schema, "anthropic_api_key_ref"),
             "claude_code manifest missing anthropic_api_key_ref"
    end

    test "claude_code manifest has config_schema with esrd_url" do
      {:ok, manifest} = Manifest.parse(@cc_manifest_path)
      schema = manifest.declares[:config_schema] || %{}

      assert Map.has_key?(schema, "esrd_url"),
             "claude_code manifest missing esrd_url in config_schema"
    end
  end
end

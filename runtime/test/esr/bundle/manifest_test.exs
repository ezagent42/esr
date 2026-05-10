defmodule Esr.Bundle.ManifestTest do
  @moduledoc """
  Tests for `Esr.Bundle.Manifest`.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md` §5.3.
  Phase 4 (Task 4.1).
  """
  use ExUnit.Case, async: true

  alias Esr.Bundle.Manifest

  @tmp_dir Path.join(System.tmp_dir!(), "esr_bundle_manifest_test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp manifest_path(yaml) do
    path = Path.join(@tmp_dir, "manifest.yaml")
    File.write!(path, yaml)
    path
  end

  defp minimal_yaml do
    """
    schema_version: 1
    name: feishu-cc
    version: 0.1.0
    description: Feishu chat → Claude Code agent
    dependencies:
      plugins: [feishu, claude_code]
      bundles: []
    """
  end

  describe "parse/1 happy path" do
    test "parses a fully populated manifest" do
      assert {:ok, m} = Manifest.parse(manifest_path(minimal_yaml()))
      assert m.schema_version == 1
      assert m.name == "feishu-cc"
      assert m.version == "0.1.0"
      assert m.description == "Feishu chat → Claude Code agent"
      assert m.dependencies == %{plugins: ["feishu", "claude_code"], bundles: []}
      assert m.path == manifest_path(minimal_yaml())
    end

    test "description defaults to empty string when absent" do
      yaml = """
      schema_version: 1
      name: tiny
      version: 0.0.1
      dependencies:
        plugins: [foo]
      """

      assert {:ok, m} = Manifest.parse(manifest_path(yaml))
      assert m.description == ""
      assert m.dependencies == %{plugins: ["foo"], bundles: []}
    end

    test "bundles list defaults to [] when absent" do
      yaml = """
      schema_version: 1
      name: tiny
      version: 0.0.1
      dependencies:
        plugins: [foo]
      """

      assert {:ok, m} = Manifest.parse(manifest_path(yaml))
      assert m.dependencies.bundles == []
    end
  end

  describe "parse_string/1" do
    test "round-trips identical to parse/1 with path: nil" do
      assert {:ok, m} = Manifest.parse_string(minimal_yaml())
      assert m.path == nil
      assert m.name == "feishu-cc"
    end
  end

  describe "schema_version" do
    test "missing schema_version → :missing_field" do
      yaml = """
      name: x
      version: 0.0.1
      dependencies:
        plugins: [a]
      """

      assert {:error, {:missing_field, "schema_version"}} =
               Manifest.parse(manifest_path(yaml))
    end

    test "schema_version != 1 → :schema_version_mismatch" do
      yaml = """
      schema_version: 2
      name: x
      version: 0.0.1
      dependencies:
        plugins: [a]
      """

      assert {:error, {:schema_version_mismatch, expected: 1, got: 2}} =
               Manifest.parse(manifest_path(yaml))
    end
  end

  describe "missing required fields" do
    test "missing name" do
      yaml = """
      schema_version: 1
      version: 0.0.1
      dependencies:
        plugins: [a]
      """

      assert {:error, {:missing_field, "name"}} = Manifest.parse(manifest_path(yaml))
    end

    test "empty name" do
      yaml = """
      schema_version: 1
      name: ""
      version: 0.0.1
      dependencies:
        plugins: [a]
      """

      assert {:error, {:missing_field, "name"}} = Manifest.parse(manifest_path(yaml))
    end

    test "missing version" do
      yaml = """
      schema_version: 1
      name: x
      dependencies:
        plugins: [a]
      """

      assert {:error, {:missing_field, "version"}} = Manifest.parse(manifest_path(yaml))
    end

    test "missing dependencies block" do
      yaml = """
      schema_version: 1
      name: x
      version: 0.0.1
      """

      assert {:error, {:missing_field, "dependencies"}} = Manifest.parse(manifest_path(yaml))
    end

    test "missing dependencies.plugins" do
      yaml = """
      schema_version: 1
      name: x
      version: 0.0.1
      dependencies:
        bundles: []
      """

      assert {:error, {:missing_field, "dependencies.plugins"}} =
               Manifest.parse(manifest_path(yaml))
    end
  end

  describe "malformed dependencies" do
    test "plugins is not a list" do
      yaml = """
      schema_version: 1
      name: x
      version: 0.0.1
      dependencies:
        plugins: "feishu"
      """

      assert {:error, {:invalid_dependency_list, "plugins", "feishu"}} =
               Manifest.parse(manifest_path(yaml))
    end

    test "plugins entry is non-string" do
      yaml = """
      schema_version: 1
      name: x
      version: 0.0.1
      dependencies:
        plugins: [1, 2]
      """

      assert {:error, {:invalid_dependency_entry, "plugins", 1}} =
               Manifest.parse(manifest_path(yaml))
    end

    test "plugins contains empty string" do
      yaml = """
      schema_version: 1
      name: x
      version: 0.0.1
      dependencies:
        plugins: [""]
      """

      assert {:error, {:invalid_dependency_entry, "plugins", ""}} =
               Manifest.parse(manifest_path(yaml))
    end

    test "bundles is not a list" do
      yaml = """
      schema_version: 1
      name: x
      version: 0.0.1
      dependencies:
        plugins: [foo]
        bundles: "nope"
      """

      assert {:error, {:invalid_dependency_list, "bundles", "nope"}} =
               Manifest.parse(manifest_path(yaml))
    end
  end

  describe "file + yaml errors" do
    test "absent file" do
      assert {:error, {:read_failed, :enoent, _}} =
               Manifest.parse(Path.join(@tmp_dir, "ghost.yaml"))
    end

    test "non-map yaml" do
      yaml = "- 1\n- 2\n"
      assert {:error, {:not_a_map, _}} = Manifest.parse(manifest_path(yaml))
    end

    test "malformed yaml" do
      yaml = "schema_version: 1\nname: x\n  bad indent: oops\n"
      assert {:error, _} = Manifest.parse(manifest_path(yaml))
    end
  end
end

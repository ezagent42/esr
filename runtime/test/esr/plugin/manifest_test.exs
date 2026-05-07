defmodule Esr.Plugin.ManifestTest do
  @moduledoc """
  Tests for `Esr.Plugin.Manifest`.

  Spec: `docs/superpowers/specs/2026-05-04-plugin-mechanism-design.md` §四.

  Phase-1 validation focus:
    - required fields present
    - name is kebab-case + unique
    - depends_on shape
    - cap-namespace-prefix enforcement
    - module existence via `Code.ensure_loaded?/1`
  """
  use ExUnit.Case, async: true

  alias Esr.Plugin.Manifest

  @tmp_dir Path.join(System.tmp_dir!(), "esr_manifest_test")

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

  defp minimal_manifest_yaml(name \\ "demo") do
    """
    name: #{name}
    version: 0.1.0
    description: Test plugin.
    depends_on:
      core: ">= 0.1.0"
      plugins: []
    declares: {}
    """
  end

  describe "parse/1" do
    test "returns {:ok, struct} for a minimal valid manifest" do
      assert {:ok, manifest} = Manifest.parse(manifest_path(minimal_manifest_yaml()))
      assert manifest.name == "demo"
      assert manifest.version == "0.1.0"
      assert manifest.depends_on.core == ">= 0.1.0"
      assert manifest.depends_on.plugins == []
    end

    test "absent file returns {:error, :enoent}" do
      assert {:error, {:read_failed, :enoent, _}} =
               Manifest.parse(Path.join(@tmp_dir, "ghost.yaml"))
    end

    test "missing required field 'name'" do
      yaml = """
      version: 0.1.0
      description: x
      """

      assert {:error, {:missing_field, "name"}} = Manifest.parse(manifest_path(yaml))
    end

    test "missing required field 'version'" do
      yaml = """
      name: demo
      description: x
      """

      assert {:error, {:missing_field, "version"}} = Manifest.parse(manifest_path(yaml))
    end

    test "name must be kebab-case OR snake_case (lowercase)" do
      yaml = """
      name: BadNameWithCaps
      version: 0.1.0
      description: x
      """

      assert {:error, {:invalid_name, "BadNameWithCaps"}} =
               Manifest.parse(manifest_path(yaml))
    end

    test "snake_case names are accepted (legacy `claude_code`)" do
      yaml = """
      name: claude_code
      version: 0.1.0
      description: x
      """

      assert {:ok, %{name: "claude_code"}} = Manifest.parse(manifest_path(yaml))
    end

    test "depends_on defaults to core: '>= 0.0.0', plugins: []" do
      yaml = """
      name: demo
      version: 0.1.0
      description: x
      """

      assert {:ok, manifest} = Manifest.parse(manifest_path(yaml))
      assert manifest.depends_on.core == ">= 0.0.0"
      assert manifest.depends_on.plugins == []
    end

    test "captures declared capability list" do
      yaml = """
      name: feishu
      version: 0.1.0
      description: x
      declares:
        capabilities:
          - feishu/notify
          - feishu/bind
      """

      assert {:ok, manifest} = Manifest.parse(manifest_path(yaml))
      assert manifest.declares.capabilities == ["feishu/notify", "feishu/bind"]
    end
  end

  describe "validate/1 — capability namespace prefix" do
    test "all caps prefixed with plugin name → ok" do
      manifest = %Manifest{
        name: "feishu",
        version: "0.1.0",
        description: "x",
        depends_on: %{core: ">= 0.0.0", plugins: []},
        declares: %{capabilities: ["feishu/notify", "feishu/bind"]}
      }

      assert :ok == Manifest.validate(manifest)
    end

    test "cap NOT prefixed with plugin name → {:error, :bad_cap_prefix}" do
      manifest = %Manifest{
        name: "feishu",
        version: "0.1.0",
        description: "x",
        depends_on: %{core: ">= 0.0.0", plugins: []},
        declares: %{capabilities: ["feishu/notify", "cc/launch"]}
      }

      assert {:error, {:bad_cap_prefix, "cc/launch", "feishu"}} ==
               Manifest.validate(manifest)
    end

    test "missing slash in cap name is rejected" do
      manifest = %Manifest{
        name: "feishu",
        version: "0.1.0",
        description: "x",
        depends_on: %{core: ">= 0.0.0", plugins: []},
        declares: %{capabilities: ["feishu_notify"]}
      }

      assert {:error, {:bad_cap_shape, "feishu_notify"}} == Manifest.validate(manifest)
    end
  end

  describe "validate/1 — module existence (Code.ensure_loaded?)" do
    test "absent module in entities is rejected" do
      manifest = %Manifest{
        name: "demo",
        version: "0.1.0",
        description: "x",
        depends_on: %{core: ">= 0.0.0", plugins: []},
        declares: %{
          entities: [%{module: "Definitely.Not.A.Real.Module", kind: "stateful"}]
        }
      }

      assert {:error, {:unknown_module, "Definitely.Not.A.Real.Module"}} ==
               Manifest.validate(manifest)
    end

    test "existing module in entities passes" do
      manifest = %Manifest{
        name: "demo",
        version: "0.1.0",
        description: "x",
        depends_on: %{core: ">= 0.0.0", plugins: []},
        declares: %{entities: [%{module: "Esr.Entity.Server", kind: "stateful"}]}
      }

      assert :ok == Manifest.validate(manifest)
    end
  end

  describe "config_schema: parsing (Phase 7.1)" do
    @manifest_with_schema """
    name: test-plugin
    version: 0.1.0
    description: test
    depends_on:
      core: ">= 0.1.0"
      plugins: []
    declares: {}
    config_schema:
      http_proxy:
        type: string
        description: "HTTP proxy URL."
        default: ""
      verbose:
        type: boolean
        description: "Enable verbose logging."
        default: false
    """

    @manifest_missing_description """
    name: test-plugin
    version: 0.1.0
    description: test
    depends_on:
      core: ">= 0.1.0"
      plugins: []
    declares: {}
    config_schema:
      bad_key:
        type: string
        default: ""
    """

    @manifest_missing_default """
    name: test-plugin
    version: 0.1.0
    description: test
    depends_on:
      core: ">= 0.1.0"
      plugins: []
    declares: {}
    config_schema:
      bad_key:
        type: string
        description: "Missing default."
    """

    @manifest_unknown_type """
    name: test-plugin
    version: 0.1.0
    description: test
    depends_on:
      core: ">= 0.1.0"
      plugins: []
    declares: {}
    config_schema:
      bad_key:
        type: fancy_type
        description: "Unknown type."
        default: ""
    """

    defp parse_yaml_string(content) do
      path = System.tmp_dir!() |> Path.join("test_manifest_#{:rand.uniform(9999)}.yaml")
      File.write!(path, content)
      result = Esr.Plugin.Manifest.parse(path)
      File.rm(path)
      result
    end

    test "valid config_schema parses into declares.config_schema map" do
      {:ok, manifest} = parse_yaml_string(@manifest_with_schema)
      schema = manifest.declares[:config_schema]
      assert is_map(schema)
      assert schema["http_proxy"]["type"] == "string"
      assert schema["http_proxy"]["default"] == ""
      assert schema["verbose"]["type"] == "boolean"
      assert schema["verbose"]["default"] == false
    end

    test "missing description field returns config_schema_missing_field error" do
      assert {:error, {:config_schema_missing_field, "bad_key", "description"}} =
               parse_yaml_string(@manifest_missing_description)
    end

    test "missing default field returns config_schema_missing_field error" do
      assert {:error, {:config_schema_missing_field, "bad_key", "default"}} =
               parse_yaml_string(@manifest_missing_default)
    end

    test "unknown type returns config_schema_unknown_type error" do
      assert {:error, {:config_schema_unknown_type, "bad_key", "fancy_type"}} =
               parse_yaml_string(@manifest_unknown_type)
    end

    test "manifest without config_schema: has empty declares.config_schema" do
      yaml = """
      name: test-plugin
      version: 0.1.0
      description: test
      depends_on:
        core: ">= 0.1.0"
        plugins: []
      declares: {}
      """

      {:ok, manifest} = parse_yaml_string(yaml)
      assert manifest.declares[:config_schema] == %{} or is_nil(manifest.declares[:config_schema])
    end
  end

  describe "parse/1 — hot_reloadable field (HR-1)" do
    defp hr1_yaml(extra \\ "") do
      """
      name: test-plugin
      version: 0.1.0
      description: test
      depends_on:
        core: ">= 0.1.0"
        plugins: []
      declares: {}
      #{extra}
      """
    end

    test "hot_reloadable: true → manifest.hot_reloadable == true" do
      path = manifest_path(hr1_yaml("hot_reloadable: true"))
      assert {:ok, manifest} = Manifest.parse(path)
      assert manifest.hot_reloadable == true
    end

    test "hot_reloadable: false → manifest.hot_reloadable == false" do
      path = manifest_path(hr1_yaml("hot_reloadable: false"))
      assert {:ok, manifest} = Manifest.parse(path)
      assert manifest.hot_reloadable == false
    end

    test "absent hot_reloadable → manifest.hot_reloadable == false (default)" do
      path = manifest_path(hr1_yaml())
      assert {:ok, manifest} = Manifest.parse(path)
      assert manifest.hot_reloadable == false
    end

    test "hot_reloadable: 'yes' (string) → {:error, {:invalid_hot_reloadable, \"yes\"}}" do
      path = manifest_path(hr1_yaml("hot_reloadable: \"yes\""))
      assert {:error, {:invalid_hot_reloadable, "yes"}} = Manifest.parse(path)
    end

    test "hot_reloadable: 1 (integer) → {:error, {:invalid_hot_reloadable, 1}}" do
      path = manifest_path(hr1_yaml("hot_reloadable: 1"))
      assert {:error, {:invalid_hot_reloadable, 1}} = Manifest.parse(path)
    end
  end
end

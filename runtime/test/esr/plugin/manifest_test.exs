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
end

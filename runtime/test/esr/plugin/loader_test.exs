defmodule Esr.Plugin.LoaderTest do
  @moduledoc """
  Tests for `Esr.Plugin.Loader`.

  Spec: `docs/superpowers/specs/2026-05-04-plugin-mechanism-design.md` §五.

  Phase-1 focus:
    - discover/1 scans a plugin root for manifest.yaml files
    - topo_sort_enabled/2 orders by depends_on, rejects cycles + missing deps
    - start_plugin/2 registers contributions (we cover capabilities + sidecars
      since core's registries for those are already up under
      Esr.Application).
  """
  use ExUnit.Case, async: false

  alias Esr.Plugin.{Loader, Manifest}

  @tmp_dir Path.join(System.tmp_dir!(), "esr_plugin_loader_test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    # HR-1: ensure the ConfigSnapshot ETS table exists before any
    # start_plugin/2 call (Application.start/2 normally does this;
    # unit tests bypass Application).
    :ok = Esr.Plugin.ConfigSnapshot.create_table()
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp write_plugin!(name, manifest_yaml) do
    plugin_dir = Path.join(@tmp_dir, name)
    File.mkdir_p!(plugin_dir)
    File.write!(Path.join(plugin_dir, "manifest.yaml"), manifest_yaml)
    plugin_dir
  end

  defp manifest_yaml(name, deps \\ []) do
    deps_block =
      case deps do
        [] -> "[]"
        list -> "\n    " <> Enum.map_join(list, "\n    ", &"- #{&1}")
      end

    """
    name: #{name}
    version: 0.1.0
    description: test plugin #{name}
    depends_on:
      core: ">= 0.0.0"
      plugins: #{deps_block}
    declares: {}
    """
  end

  describe "discover/1" do
    test "empty plugin root returns []" do
      assert {:ok, []} == Loader.discover(@tmp_dir)
    end

    test "non-existent plugin root returns []" do
      assert {:ok, []} == Loader.discover(Path.join(@tmp_dir, "missing"))
    end

    test "single plugin discovered as {name, manifest}" do
      write_plugin!("alpha", manifest_yaml("alpha"))

      assert {:ok, [{"alpha", %Manifest{name: "alpha"}}]} = Loader.discover(@tmp_dir)
    end

    test "multiple plugins all discovered (sorted by name)" do
      write_plugin!("zulu", manifest_yaml("zulu"))
      write_plugin!("alpha", manifest_yaml("alpha"))
      write_plugin!("mike", manifest_yaml("mike"))

      assert {:ok, list} = Loader.discover(@tmp_dir)
      assert Enum.map(list, &elem(&1, 0)) == ["alpha", "mike", "zulu"]
    end

    test "manifest.yaml parse failure surfaces as :error tagged with plugin dir name" do
      bad_dir = Path.join(@tmp_dir, "bad")
      File.mkdir_p!(bad_dir)
      File.write!(Path.join(bad_dir, "manifest.yaml"), "name: bad\n# missing version\n")

      assert {:error, {:manifest_invalid, "bad", _reason}} = Loader.discover(@tmp_dir)
    end
  end

  describe "topo_sort_enabled/2" do
    test "no deps → input order preserved (alphabetical from discover)" do
      a = %Manifest{name: "a", depends_on: %{core: ">= 0.0.0", plugins: []}, declares: %{}}
      b = %Manifest{name: "b", depends_on: %{core: ">= 0.0.0", plugins: []}, declares: %{}}

      assert {:ok, [{"a", _}, {"b", _}]} =
               Loader.topo_sort_enabled([{"a", a}, {"b", b}], ["a", "b"])
    end

    test "linear dependency order is honored" do
      # b depends on a; should appear after a
      a = %Manifest{name: "a", depends_on: %{core: ">= 0.0.0", plugins: []}, declares: %{}}

      b = %Manifest{
        name: "b",
        depends_on: %{core: ">= 0.0.0", plugins: ["a"]},
        declares: %{}
      }

      assert {:ok, [{"a", _}, {"b", _}]} =
               Loader.topo_sort_enabled([{"b", b}, {"a", a}], ["a", "b"])
    end

    test "missing dep → {:error, {:missing_dep, ...}}" do
      b = %Manifest{
        name: "b",
        depends_on: %{core: ">= 0.0.0", plugins: ["a"]},
        declares: %{}
      }

      # 'a' is in discovered list but NOT in enabled list — so 'b' references
      # a disabled plugin, which the loader treats as missing.
      a = %Manifest{name: "a", depends_on: %{core: ">= 0.0.0", plugins: []}, declares: %{}}

      assert {:error, {:missing_dep, "b", "a"}} =
               Loader.topo_sort_enabled([{"a", a}, {"b", b}], ["b"])
    end

    test "cycle → {:error, :cycle}" do
      a =
        %Manifest{
          name: "a",
          depends_on: %{core: ">= 0.0.0", plugins: ["b"]},
          declares: %{}
        }

      b =
        %Manifest{
          name: "b",
          depends_on: %{core: ">= 0.0.0", plugins: ["a"]},
          declares: %{}
        }

      assert {:error, :cycle} =
               Loader.topo_sort_enabled([{"a", a}, {"b", b}], ["a", "b"])
    end

    test "enabled subset only returns enabled plugins (skips disabled)" do
      a = %Manifest{name: "a", depends_on: %{core: ">= 0.0.0", plugins: []}, declares: %{}}
      b = %Manifest{name: "b", depends_on: %{core: ">= 0.0.0", plugins: []}, declares: %{}}

      assert {:ok, [{"a", _}]} =
               Loader.topo_sort_enabled([{"a", a}, {"b", b}], ["a"])
    end
  end

  describe "start_plugin/2 — Phase 1 contribution registration" do
    test "registers python_sidecars into Esr.Resource.Sidecar.Registry" do
      manifest = %Manifest{
        name: "demo",
        version: "0.1.0",
        description: "x",
        depends_on: %{core: ">= 0.0.0", plugins: []},
        declares: %{
          python_sidecars: [
            %{"adapter_type" => "demo_adapter", "python_module" => "demo_runner"}
          ]
        }
      }

      assert {:ok, _} = Loader.start_plugin("demo", manifest)
      assert {:ok, "demo_runner"} == Esr.Resource.Sidecar.Registry.lookup("demo_adapter")

      # cleanup
      :ok = Esr.Resource.Sidecar.Registry.unregister("demo_adapter")
    end

    test "stop_plugin/1 is a no-op stub returning :ok (Phase 1)" do
      assert :ok == Loader.stop_plugin("anything")
    end

    # 2026-05-10 SessionTemplate + Channel migration, Phase 1: Loader
    # registers each plugin's `channels:` entries into
    # `Esr.Channel.Registry` at start_plugin/2 time.
    test "registers manifest channels into Esr.Channel.Registry" do
      manifest = %Manifest{
        name: "demo",
        version: "0.1.0",
        description: "x",
        depends_on: %{core: ">= 0.0.0", plugins: []},
        declares: %{},
        channels: [
          %{name: "chat_proxy", module: Esr.Entity.Server, config_schema: nil},
          %{name: "mcp_stdio", module: Esr.Entity.PtyProcess, config_schema: %{"k" => "v"}}
        ]
      }

      # The Channel.Registry is a named GenServer. The test suite boots
      # Esr.Application before tests, so it's already running here. Just
      # clear it to start clean and verify the post-condition.
      :ok = Esr.Channel.Registry.clear()

      assert {:ok, _} = Loader.start_plugin("demo", manifest)
      assert {:ok, Esr.Entity.Server} == Esr.Channel.Registry.lookup("demo.chat_proxy")
      assert {:ok, Esr.Entity.PtyProcess} == Esr.Channel.Registry.lookup("demo.mcp_http")

      # cleanup
      :ok = Esr.Channel.Registry.clear()
    end

    test "manifest with empty channels: leaves the Channel.Registry untouched" do
      manifest = %Manifest{
        name: "demo",
        version: "0.1.0",
        description: "x",
        depends_on: %{core: ">= 0.0.0", plugins: []},
        declares: %{},
        channels: []
      }

      :ok = Esr.Channel.Registry.clear()
      assert {:ok, _} = Loader.start_plugin("demo", manifest)
      assert [] == Esr.Channel.Registry.list_kinds()
    end
  end

  describe "depends_on.core enforcement (Phase 7.3)" do
    defp make_manifest(core_constraint) do
      path = System.tmp_dir!() |> Path.join("test_manifest_#{:rand.uniform(99_999)}.yaml")

      content = """
      name: test-plugin
      version: 0.1.0
      description: test
      depends_on:
        core: "#{core_constraint}"
        plugins: []
      declares: {}
      """

      File.write!(path, content)
      {:ok, manifest} = Esr.Plugin.Manifest.parse(path)
      File.rm(path)
      manifest
    end

    test "plugin with satisfied core constraint starts successfully" do
      manifest = make_manifest(">= 0.1.0")
      result = Esr.Plugin.Loader.start_plugin("test-plugin", manifest)
      refute match?({:error, {:core_version_mismatch, _, _}}, result)
    end

    test "plugin requiring future core version is rejected" do
      manifest = make_manifest(">= 99.0.0")

      assert {:error, {:core_version_mismatch, ">= 99.0.0", actual_vsn}} =
               Esr.Plugin.Loader.start_plugin("test-plugin", manifest)

      assert is_binary(actual_vsn)
    end

    test "plugin without core constraint starts successfully (no constraint = unrestricted)" do
      path = System.tmp_dir!() |> Path.join("test_manifest_nocore.yaml")

      content = """
      name: test-plugin-nocore
      version: 0.1.0
      description: test
      depends_on:
        plugins: []
      declares: {}
      """

      File.write!(path, content)
      {:ok, manifest} = Esr.Plugin.Manifest.parse(path)
      File.rm(path)

      result = Esr.Plugin.Loader.start_plugin("test-plugin-nocore", manifest)
      refute match?({:error, {:core_version_mismatch, _, _}}, result)
    end
  end
end

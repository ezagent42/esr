defmodule Esr.Plugin.LoaderIntegrationTest do
  @moduledoc """
  End-to-end test that real mock plugin manifests round-trip through
  the loader pipeline: discover → topo_sort → start_plugin → core
  registries actually carry the plugin's contributions.

  Distinct from `Esr.Plugin.LoaderTest` which uses synthetic in-memory
  manifests; this test reads three actual manifest.yaml files under
  `runtime/test/fixtures/plugins/` to prove the on-disk path works
  end-to-end.

  Per user feedback 2026-05-04: "stub manifests" (PR-180's voice/feishu/
  claude_code) only proved the manifest schema is valid; they did NOT
  prove the loader can actually push contributions into core. This test
  closes that gap.
  """
  use ExUnit.Case, async: false

  alias Esr.Plugin.Loader
  alias Esr.Resource.Permission.Registry, as: PermRegistry
  alias Esr.Resource.Sidecar.Registry, as: SidecarRegistry

  @fixtures_root Path.expand("../../fixtures/plugins", __DIR__)

  setup do
    on_exit(fn ->
      # Clean up sidecar registrations our test plugins inserted so
      # parallel suites and re-runs see a fresh table.
      :ok = SidecarRegistry.unregister("mock_a_adapter")
      :ok = SidecarRegistry.unregister("mock_b_adapter")
      :ok = SidecarRegistry.unregister("mock_c_a")
      :ok = SidecarRegistry.unregister("mock_c_b")
    end)

    :ok
  end

  describe "discover/1 against real fixture manifests" do
    test "finds all 3 mock plugins" do
      assert {:ok, plugins} = Loader.discover(@fixtures_root)
      names = Enum.map(plugins, &elem(&1, 0))
      assert "mock_a" in names
      assert "mock_b" in names
      assert "mock_c" in names
    end

    test "manifest fields are populated for each plugin" do
      {:ok, plugins} = Loader.discover(@fixtures_root)
      mock_a = Enum.find(plugins, fn {n, _} -> n == "mock_a" end) |> elem(1)
      assert mock_a.version == "0.0.1"
      assert mock_a.description =~ "Mock component"
      assert mock_a.depends_on.plugins == []

      mock_b = Enum.find(plugins, fn {n, _} -> n == "mock_b" end) |> elem(1)
      assert mock_b.depends_on.plugins == ["mock_a"]
    end
  end

  describe "topo_sort_enabled/2 against real fixtures" do
    test "mock_a comes before mock_b when both enabled" do
      {:ok, plugins} = Loader.discover(@fixtures_root)

      assert {:ok, ordered} =
               Loader.topo_sort_enabled(plugins, ["mock_a", "mock_b", "mock_c"])

      ordered_names = Enum.map(ordered, &elem(&1, 0))
      a_idx = Enum.find_index(ordered_names, &(&1 == "mock_a"))
      b_idx = Enum.find_index(ordered_names, &(&1 == "mock_b"))
      assert a_idx < b_idx, "mock_a (#{a_idx}) must come before mock_b (#{b_idx})"
    end

    test "enabling mock_b without mock_a fails with missing_dep" do
      {:ok, plugins} = Loader.discover(@fixtures_root)

      assert {:error, {:missing_dep, "mock_b", "mock_a"}} =
               Loader.topo_sort_enabled(plugins, ["mock_b"])
    end
  end

  describe "start_plugin/2 — Component-only (mock_a)" do
    test "registers python_sidecar entry into Esr.Resource.Sidecar.Registry" do
      {:ok, plugins} = Loader.discover(@fixtures_root)
      mock_a = Enum.find_value(plugins, fn {n, m} -> if n == "mock_a", do: m end)

      assert {:ok, :registered} = Loader.start_plugin("mock_a", mock_a)

      assert {:ok, "mock_a_runner"} == SidecarRegistry.lookup("mock_a_adapter")
    end

    test "registers capability into Esr.Resource.Permission.Registry" do
      {:ok, plugins} = Loader.discover(@fixtures_root)
      mock_a = Enum.find_value(plugins, fn {n, m} -> if n == "mock_a", do: m end)

      assert {:ok, :registered} = Loader.start_plugin("mock_a", mock_a)

      assert PermRegistry.declared?("mock_a/ping"),
             "Permission.Registry should know about mock_a/ping after start_plugin"
    end
  end

  describe "start_plugin/2 — Topology with deps (mock_b)" do
    test "second plugin's contributions land alongside the first" do
      {:ok, plugins} = Loader.discover(@fixtures_root)
      {:ok, ordered} = Loader.topo_sort_enabled(plugins, ["mock_a", "mock_b"])

      for {name, m} <- ordered do
        assert {:ok, :registered} = Loader.start_plugin(name, m)
      end

      # Both plugins' caps + sidecars are present.
      assert {:ok, "mock_a_runner"} == SidecarRegistry.lookup("mock_a_adapter")
      assert {:ok, "mock_b_runner"} == SidecarRegistry.lookup("mock_b_adapter")
      assert PermRegistry.declared?("mock_a/ping")
      assert PermRegistry.declared?("mock_b/echo")
    end
  end

  describe "start_plugin/2 — Composite session declaration (mock_c)" do
    test "registers multiple caps + multiple sidecars + passes entity validation" do
      {:ok, plugins} = Loader.discover(@fixtures_root)
      mock_c = Enum.find_value(plugins, fn {n, m} -> if n == "mock_c", do: m end)

      assert {:ok, :registered} = Loader.start_plugin("mock_c", mock_c)

      assert {:ok, "mock_c_runner_a"} == SidecarRegistry.lookup("mock_c_a")
      assert {:ok, "mock_c_runner_b"} == SidecarRegistry.lookup("mock_c_b")
      assert PermRegistry.declared?("mock_c/cmd1")
      assert PermRegistry.declared?("mock_c/cmd2")
      assert PermRegistry.declared?("mock_c/admin")
    end
  end

  describe "full pipeline: 3 plugins, varying types, single integration sweep" do
    test "discover → topo_sort → start each → all 3 plugins' contributions present" do
      {:ok, plugins} = Loader.discover(@fixtures_root)

      assert {:ok, ordered} =
               Loader.topo_sort_enabled(plugins, ["mock_a", "mock_b", "mock_c"])

      assert length(ordered) == 3

      for {name, manifest} <- ordered do
        assert {:ok, :registered} = Loader.start_plugin(name, manifest),
               "start_plugin(#{name}) failed"
      end

      # 4 sidecar mappings registered (1 from a, 1 from b, 2 from c)
      registered_types =
        SidecarRegistry.list()
        |> Enum.map(&elem(&1, 0))
        |> Enum.filter(&String.starts_with?(&1, "mock_"))

      assert MapSet.new(registered_types) ==
               MapSet.new(["mock_a_adapter", "mock_b_adapter", "mock_c_a", "mock_c_b"])

      # 6 capabilities registered total (1 + 1 + 3, plus prefix-validated).
      for cap <- ~w(mock_a/ping mock_b/echo mock_c/cmd1 mock_c/cmd2 mock_c/admin) do
        assert PermRegistry.declared?(cap),
               "expected Permission.Registry to know #{cap} after full sweep"
      end
    end
  end
end

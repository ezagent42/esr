defmodule Esr.Plugin.LoaderIntegrationTest do
  @moduledoc """
  End-to-end test that real plugin manifests round-trip through the
  loader pipeline: discover → topo_sort → start_plugin → core
  registries actually carry the plugin's contributions.

  Distinct from `Esr.Plugin.LoaderTest` which uses synthetic in-memory
  manifests; this test reads three actual `manifest.yaml` files under
  `runtime/test/fixtures/plugins/` to prove the on-disk path works
  end-to-end.

  The three fixtures map to Spec B §二's three plugin types:

    - `bare_component` — Component-only (1 cap, 1 sidecar, no deps)
    - `dependent_topology` — Topology fragment with `depends_on:
      [bare_component]`
    - `composite_session` — Session declaration (multi-cap, multi-
      sidecar, entity reference)

  Per user feedback 2026-05-04: the stub manifests shipped in PR-180
  (voice/feishu/claude_code) only proved the manifest schema parses;
  they did NOT prove the loader can push contributions into core
  registries. This test closes that gap.
  """
  use ExUnit.Case, async: false

  alias Esr.Plugin.Loader
  alias Esr.Resource.Permission.Registry, as: PermRegistry
  alias Esr.Resource.Sidecar.Registry, as: SidecarRegistry

  @fixtures_root Path.expand("../../fixtures/plugins", __DIR__)
  @fixture_names ~w(bare_component dependent_topology composite_session)

  setup do
    on_exit(fn ->
      # Clean up sidecar registrations our fixture plugins inserted so
      # parallel suites and re-runs see a fresh table.
      :ok = SidecarRegistry.unregister("bare_component_adapter")
      :ok = SidecarRegistry.unregister("dependent_topology_adapter")
      :ok = SidecarRegistry.unregister("composite_session_alpha")
      :ok = SidecarRegistry.unregister("composite_session_beta")
    end)

    :ok
  end

  describe "discover/1 against real fixture manifests" do
    test "finds all 3 fixture plugins" do
      assert {:ok, plugins} = Loader.discover(@fixtures_root)
      names = Enum.map(plugins, &elem(&1, 0))
      assert Enum.sort(names) == Enum.sort(@fixture_names)
    end

    test "manifest fields are populated for each plugin" do
      {:ok, plugins} = Loader.discover(@fixtures_root)

      bare = Enum.find(plugins, fn {n, _} -> n == "bare_component" end) |> elem(1)
      assert bare.version == "0.0.1"
      assert bare.description =~ "Component-shape"
      assert bare.depends_on.plugins == []

      dep = Enum.find(plugins, fn {n, _} -> n == "dependent_topology" end) |> elem(1)
      assert dep.depends_on.plugins == ["bare_component"]
    end
  end

  describe "topo_sort_enabled/2 against real fixtures" do
    test "bare_component comes before dependent_topology when both enabled" do
      {:ok, plugins} = Loader.discover(@fixtures_root)

      assert {:ok, ordered} =
               Loader.topo_sort_enabled(plugins, @fixture_names)

      ordered_names = Enum.map(ordered, &elem(&1, 0))
      bare_idx = Enum.find_index(ordered_names, &(&1 == "bare_component"))
      dep_idx = Enum.find_index(ordered_names, &(&1 == "dependent_topology"))

      assert bare_idx < dep_idx,
             "bare_component (#{bare_idx}) must come before dependent_topology (#{dep_idx})"
    end

    test "enabling dependent_topology without bare_component fails with missing_dep" do
      {:ok, plugins} = Loader.discover(@fixtures_root)

      assert {:error, {:missing_dep, "dependent_topology", "bare_component"}} =
               Loader.topo_sort_enabled(plugins, ["dependent_topology"])
    end
  end

  describe "start_plugin/2 — Component-only (bare_component)" do
    test "registers python_sidecar entry into Esr.Resource.Sidecar.Registry" do
      {:ok, plugins} = Loader.discover(@fixtures_root)

      bare =
        Enum.find_value(plugins, fn {n, m} -> if n == "bare_component", do: m end)

      assert {:ok, :registered} = Loader.start_plugin("bare_component", bare)

      assert {:ok, "bare_component_runner"} ==
               SidecarRegistry.lookup("bare_component_adapter")
    end

    test "registers capability into Esr.Resource.Permission.Registry" do
      {:ok, plugins} = Loader.discover(@fixtures_root)

      bare =
        Enum.find_value(plugins, fn {n, m} -> if n == "bare_component", do: m end)

      assert {:ok, :registered} = Loader.start_plugin("bare_component", bare)

      assert PermRegistry.declared?("bare_component/ping"),
             "Permission.Registry should know about bare_component/ping after start_plugin"
    end
  end

  describe "start_plugin/2 — Topology with deps (dependent_topology)" do
    test "downstream plugin's contributions land alongside the upstream's" do
      {:ok, plugins} = Loader.discover(@fixtures_root)

      {:ok, ordered} =
        Loader.topo_sort_enabled(plugins, ["bare_component", "dependent_topology"])

      for {name, m} <- ordered do
        assert {:ok, :registered} = Loader.start_plugin(name, m)
      end

      assert {:ok, "bare_component_runner"} ==
               SidecarRegistry.lookup("bare_component_adapter")

      assert {:ok, "dependent_topology_runner"} ==
               SidecarRegistry.lookup("dependent_topology_adapter")

      assert PermRegistry.declared?("bare_component/ping")
      assert PermRegistry.declared?("dependent_topology/echo")
    end
  end

  describe "start_plugin/2 — Composite session declaration (composite_session)" do
    test "registers multiple caps + multiple sidecars + passes entity validation" do
      {:ok, plugins} = Loader.discover(@fixtures_root)

      composite =
        Enum.find_value(plugins, fn {n, m} -> if n == "composite_session", do: m end)

      assert {:ok, :registered} = Loader.start_plugin("composite_session", composite)

      assert {:ok, "composite_session_runner_alpha"} ==
               SidecarRegistry.lookup("composite_session_alpha")

      assert {:ok, "composite_session_runner_beta"} ==
               SidecarRegistry.lookup("composite_session_beta")

      for cap <- ~w(composite_session/cmd1 composite_session/cmd2 composite_session/admin) do
        assert PermRegistry.declared?(cap)
      end
    end
  end

  describe "full pipeline: 3 plugins, varying types, single integration sweep" do
    test "discover → topo_sort → start each → all 3 plugins' contributions present" do
      {:ok, plugins} = Loader.discover(@fixtures_root)

      assert {:ok, ordered} = Loader.topo_sort_enabled(plugins, @fixture_names)
      assert length(ordered) == 3

      for {name, manifest} <- ordered do
        assert {:ok, :registered} = Loader.start_plugin(name, manifest),
               "start_plugin(#{name}) failed"
      end

      # 4 sidecar mappings registered (1 + 1 + 2)
      expected_adapters = [
        "bare_component_adapter",
        "dependent_topology_adapter",
        "composite_session_alpha",
        "composite_session_beta"
      ]

      registered_types =
        SidecarRegistry.list()
        |> Enum.map(&elem(&1, 0))
        |> Enum.filter(&(&1 in expected_adapters))

      assert MapSet.new(registered_types) == MapSet.new(expected_adapters)

      # 5 capabilities registered total (1 + 1 + 3).
      for cap <- ~w(
            bare_component/ping
            dependent_topology/echo
            composite_session/cmd1
            composite_session/cmd2
            composite_session/admin
          ) do
        assert PermRegistry.declared?(cap),
               "expected Permission.Registry to know #{cap} after full sweep"
      end
    end
  end
end

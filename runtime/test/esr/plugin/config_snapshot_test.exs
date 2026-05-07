defmodule Esr.Plugin.ConfigSnapshotTest do
  @moduledoc """
  Tests for `Esr.Plugin.ConfigSnapshot`.

  The ETS table is created fresh per test to ensure isolation.
  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §5.
  """
  use ExUnit.Case, async: false

  alias Esr.Plugin.ConfigSnapshot

  @table :esr_plugin_config_snapshots

  setup do
    # Drop the table if it exists from a prior test run, then recreate it.
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table)
    end

    ConfigSnapshot.create_table()
    :ok
  end

  describe "get/1 — absent plugin" do
    test "returns %{} when no snapshot exists for plugin" do
      assert %{} == ConfigSnapshot.get("no_such_plugin")
    end
  end

  describe "init/2 + get/1" do
    test "stores and retrieves the snapshot map" do
      snapshot = %{"http_proxy" => "http://proxy.example.com", "log_level" => "debug"}
      :ok = ConfigSnapshot.init("my_plugin", snapshot)
      assert snapshot == ConfigSnapshot.get("my_plugin")
    end

    test "overwrites an existing snapshot for the same plugin" do
      :ok = ConfigSnapshot.init("my_plugin", %{"k" => "v1"})
      :ok = ConfigSnapshot.init("my_plugin", %{"k" => "v2"})
      assert %{"k" => "v2"} == ConfigSnapshot.get("my_plugin")
    end

    test "snapshots for different plugins are independent" do
      :ok = ConfigSnapshot.init("plugin_a", %{"x" => "1"})
      :ok = ConfigSnapshot.init("plugin_b", %{"y" => "2"})
      assert %{"x" => "1"} == ConfigSnapshot.get("plugin_a")
      assert %{"y" => "2"} == ConfigSnapshot.get("plugin_b")
    end
  end

  describe "update/1" do
    # update/1 calls Esr.Plugin.Config.resolve/2. We stub this via a mock
    # config snapshot: because Config.resolve reads yaml files, and we
    # control those paths via test helpers, we bypass Config.resolve by
    # directly storing a stub into the ETS table and then calling update/1
    # with a pre-seeded snapshot so we can verify the roundtrip contract.
    #
    # In production, update/1 calls Config.resolve(plugin_name) with no
    # path opts (reads the default global layer). For unit testing, we
    # verify only the ETS contract: after update/1, get/1 returns the
    # resolved map.

    test "update/1 replaces snapshot with current Config.resolve output" do
      # Seed the global plugins yaml with a known value for "test_plugin".
      tmp = System.tmp_dir!() |> Path.join("hr1_snapshot_update_#{:rand.uniform(99_999)}.yaml")
      File.write!(tmp, "config:\n  test_plugin:\n    log_level: \"debug\"\n")

      # Init with a stale snapshot.
      :ok = ConfigSnapshot.init("test_plugin", %{"log_level" => "info"})

      # Now call update/1 using the path override mechanism.
      # update/1 in production calls Config.resolve("test_plugin").
      # For testing, we call the internal update helper with an explicit path.
      :ok = ConfigSnapshot.update_with_path("test_plugin", global_path: tmp)

      assert %{"log_level" => "debug"} == ConfigSnapshot.get("test_plugin")

      File.rm(tmp)
    end
  end
end

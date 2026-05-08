defmodule Esr.Resource.Media.PluginRegistryTest do
  use ExUnit.Case, async: false
  alias Esr.Resource.Media.PluginRegistry

  setup do
    # PluginRegistry is started by Esr.Application.
    # In tests, ensure the ETS table is empty before each test
    # by clearing entries we registered. (Don't restart the GenServer —
    # other tests may depend on it.)
    on_exit(fn ->
      # Clean up the test plugins
      PluginRegistry.unregister("test_plugin_a")
      PluginRegistry.unregister("test_plugin_b")
      PluginRegistry.unregister("feishu_test")
      PluginRegistry.unregister("cc_test")
    end)
    :ok
  end

  test "register/2 stores inbound/outbound; lookup/1 returns them" do
    PluginRegistry.register("test_plugin_a", %{inbound: [:image, :file], outbound: [:image, :file]})
    assert {:ok, %{inbound: [:image, :file], outbound: [:image, :file]}} =
             PluginRegistry.lookup("test_plugin_a")
  end

  test "lookup/1 returns :not_registered for unknown plugin" do
    assert {:error, :not_registered} = PluginRegistry.lookup("nonexistent_xyz_plugin")
  end

  test "supports?/3 returns true/false based on registered direction" do
    PluginRegistry.register("cc_test", %{inbound: [:image], outbound: []})
    assert PluginRegistry.supports?("cc_test", :inbound, :image) == true
    assert PluginRegistry.supports?("cc_test", :inbound, :audio) == false
    assert PluginRegistry.supports?("cc_test", :outbound, :image) == false
    assert PluginRegistry.supports?("nonexistent_xyz_plugin", :inbound, :image) == false
  end

  test "register/2 overwrites previous registration for same plugin" do
    PluginRegistry.register("test_plugin_b", %{inbound: [:image], outbound: []})
    PluginRegistry.register("test_plugin_b", %{inbound: [:image, :file], outbound: [:image]})
    assert {:ok, %{inbound: [:image, :file], outbound: [:image]}} =
             PluginRegistry.lookup("test_plugin_b")
  end

  test "unregister/1 removes the entry" do
    PluginRegistry.register("test_plugin_a", %{inbound: [:image], outbound: []})
    assert {:ok, _} = PluginRegistry.lookup("test_plugin_a")
    PluginRegistry.unregister("test_plugin_a")
    assert {:error, :not_registered} = PluginRegistry.lookup("test_plugin_a")
  end
end

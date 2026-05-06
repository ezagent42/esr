defmodule Esr.Resource.ChatScope.RegistryTest do
  use ExUnit.Case, async: false

  alias Esr.Resource.ChatScope.Registry

  setup do
    assert is_pid(Process.whereis(Registry))
    :ok
  end

  describe "default workspace" do
    # Test 1: set_default_workspace/3 + get_default_workspace/2 round-trip
    test "set_default_workspace/3 then get_default_workspace/2 returns {:ok, uuid}" do
      uuid = "cccccccc-0001-4000-8000-000000000001"

      assert :ok = Registry.set_default_workspace("oc_reg1", "cli_reg1", uuid)
      assert {:ok, ^uuid} = Registry.get_default_workspace("oc_reg1", "cli_reg1")
    end

    # Test 2: unset chat → :not_found
    test "get_default_workspace/2 for an unset chat returns :not_found" do
      assert :not_found = Registry.get_default_workspace("oc_unset", "cli_unset")
    end

    # Test 3: clear_default_workspace/2 removes mapping; idempotent double-clear
    test "clear_default_workspace/2 removes mapping; calling twice does not crash" do
      uuid = "cccccccc-0003-4000-8000-000000000003"

      :ok = Registry.set_default_workspace("oc_reg3", "cli_reg3", uuid)
      assert {:ok, ^uuid} = Registry.get_default_workspace("oc_reg3", "cli_reg3")

      assert :ok = Registry.clear_default_workspace("oc_reg3", "cli_reg3")
      assert :not_found = Registry.get_default_workspace("oc_reg3", "cli_reg3")

      # Idempotent — second clear must not crash
      assert :ok = Registry.clear_default_workspace("oc_reg3", "cli_reg3")
      assert :not_found = Registry.get_default_workspace("oc_reg3", "cli_reg3")
    end
  end
end

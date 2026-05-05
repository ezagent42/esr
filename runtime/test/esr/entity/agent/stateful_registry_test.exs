defmodule Esr.Entity.Agent.StatefulRegistryTest do
  @moduledoc """
  Unit tests for `Esr.Entity.Agent.StatefulRegistry` (PR-3.2).
  """

  use ExUnit.Case, async: false

  alias Esr.Entity.Agent.StatefulRegistry

  defmodule TestPeer do
    @moduledoc false
  end

  defmodule OtherPeer do
    @moduledoc false
  end

  setup do
    # Application supervises StatefulRegistry; this setup just ensures
    # we don't pollute the prod table with test entries.
    on_exit(fn ->
      :ok = StatefulRegistry.unregister(TestPeer)
      :ok = StatefulRegistry.unregister(OtherPeer)
    end)

    :ok
  end

  test "register/1 makes stateful?/1 return true" do
    refute StatefulRegistry.stateful?(TestPeer)
    :ok = StatefulRegistry.register(TestPeer)
    assert StatefulRegistry.stateful?(TestPeer)
  end

  test "register/1 is idempotent" do
    :ok = StatefulRegistry.register(TestPeer)
    :ok = StatefulRegistry.register(TestPeer)
    assert StatefulRegistry.stateful?(TestPeer)
  end

  test "unregister/1 removes the entry" do
    :ok = StatefulRegistry.register(TestPeer)
    assert StatefulRegistry.stateful?(TestPeer)
    :ok = StatefulRegistry.unregister(TestPeer)
    refute StatefulRegistry.stateful?(TestPeer)
  end

  test "stateful?/1 returns false for never-registered modules" do
    refute StatefulRegistry.stateful?(:never_registered_module)
  end

  test "list/0 returns sorted registered modules" do
    :ok = StatefulRegistry.register(TestPeer)
    :ok = StatefulRegistry.register(OtherPeer)

    list = StatefulRegistry.list()
    assert TestPeer in list
    assert OtherPeer in list
    assert list == Enum.sort(list)
  end

  test "core PtyProcess is registered at app boot" do
    assert StatefulRegistry.stateful?(Esr.Entity.PtyProcess)
  end
end

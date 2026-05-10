defmodule Esr.SessionTemplate.FlowNodeRegistryTest do
  @moduledoc """
  Tests for `Esr.SessionTemplate.FlowNodeRegistry`.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §9 + Phase 4 (Task 4.2).

  `async: false` because the registry owns a named ETS table; concurrent
  tests would race on `clear/0`.
  """
  use ExUnit.Case, async: false

  alias Esr.SessionTemplate.FlowNodeRegistry

  setup do
    case start_supervised(FlowNodeRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> FlowNodeRegistry.clear()
    end

    on_exit(fn -> FlowNodeRegistry.clear() end)
    :ok
  end

  test "init/1 seeds <route_to_agent> built-in" do
    assert {:ok, :builtin_route_to_agent} = FlowNodeRegistry.lookup("<route_to_agent>")
  end

  test "init/1 seeds Esr.Entity.Agent.MentionParser" do
    # MentionParser exists in-tree, so should be registered at boot.
    assert {:ok, Esr.Entity.Agent.MentionParser} =
             FlowNodeRegistry.lookup("Esr.Entity.Agent.MentionParser")
  end

  test "lookup/1 unknown name returns :not_found" do
    assert :not_found = FlowNodeRegistry.lookup("<nonexistent>")
    assert :not_found = FlowNodeRegistry.lookup("Some.Random.Module")
  end

  test "register/2 + lookup/1 round-trip a custom node" do
    :ok = FlowNodeRegistry.register("<custom>", :custom_value)
    assert {:ok, :custom_value} = FlowNodeRegistry.lookup("<custom>")
  end

  test "list/0 includes built-ins" do
    pairs = FlowNodeRegistry.list()
    names = Enum.map(pairs, &elem(&1, 0))
    assert "<route_to_agent>" in names
    assert "Esr.Entity.Agent.MentionParser" in names
  end

  test "clear/0 wipes custom + restores built-ins" do
    FlowNodeRegistry.register("<temp>", :gone_after_clear)
    FlowNodeRegistry.clear()
    assert :not_found = FlowNodeRegistry.lookup("<temp>")
    assert {:ok, :builtin_route_to_agent} = FlowNodeRegistry.lookup("<route_to_agent>")
  end
end

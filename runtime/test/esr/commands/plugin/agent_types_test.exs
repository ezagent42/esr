defmodule Esr.Commands.Plugin.AgentTypesTest do
  @moduledoc """
  Phase 6 (2026-05-10): `/plugin:agent-types` reads from
  `Esr.Plugin.AgentKindRegistry` (populated by `Esr.Plugin.Loader` at
  boot from each plugin manifest's `agent_kinds:` block) instead of the
  retired `Esr.Entity.Agent.Registry` (the agents.yaml cache).

  These tests register synthetic agent_kinds via the registry's public
  API and snapshot/restore on exit so they don't poison the
  application-wide registry that boot populates with the real
  `claude_code.cc` kind.
  """
  use ExUnit.Case, async: false

  alias Esr.Plugin.AgentKindRegistry

  defp empty_kind_spec(plugin, name) do
    %{
      plugin: plugin,
      name: name,
      description: "",
      handler_module: nil,
      pipeline: %{inbound: [], outbound: []},
      proxies: [],
      capabilities_required: [],
      params: []
    }
  end

  setup do
    case Process.whereis(AgentKindRegistry) do
      nil -> start_supervised!(AgentKindRegistry)
      _ -> :ok
    end

    snapshot = AgentKindRegistry.list_kinds()
    AgentKindRegistry.clear()

    on_exit(fn ->
      AgentKindRegistry.clear()
      for {key, spec} <- snapshot do
        [plugin, name] = String.split(key, ".", parts: 2)
        AgentKindRegistry.register(plugin, name, spec)
      end
    end)

    :ok
  end

  test "lists qualified agent types from plugin registry" do
    :ok = AgentKindRegistry.register("claude_code", "cc", empty_kind_spec("claude_code", "cc"))

    cmd = %{"submitted_by" => "linyilun", "args" => %{}}
    assert {:ok, %{"text" => text}} = Esr.Commands.Plugin.AgentTypes.execute(cmd)
    assert text =~ "claude_code.cc"
  end

  test "empty registry renders the no-agents message" do
    cmd = %{"submitted_by" => "linyilun", "args" => %{}}
    assert {:ok, %{"text" => text}} = Esr.Commands.Plugin.AgentTypes.execute(cmd)
    assert text =~ "no agent types declared"
  end
end

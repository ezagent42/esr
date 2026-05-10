defmodule Esr.Plugin.AgentKindRegistryTest do
  @moduledoc """
  Tests for `Esr.Plugin.AgentKindRegistry` — the ETS-backed registry
  mapping `<plugin>.<agent_kind_name>` → spec, populated at plugin boot.

  Spec: 2026-05-10-session-template-and-channel.md, Phase 6.
  """
  use ExUnit.Case, async: false

  alias Esr.Plugin.AgentKindRegistry

  setup do
    # Application boots the singleton registry; if a sibling test
    # poisoned the table, clear it so we start each test from a known
    # state.
    case Process.whereis(AgentKindRegistry) do
      nil -> start_supervised!(AgentKindRegistry)
      _ -> :ok
    end

    AgentKindRegistry.clear()
    :ok
  end

  test "register + lookup roundtrip" do
    spec = %{
      plugin: "claude_code",
      name: "cc",
      description: "Claude Code",
      handler_module: "cc_adapter_runner",
      pipeline: %{inbound: [%{"name" => "cc_proxy", "impl" => "Esr.Entity.CCProxy"}], outbound: ["cc_proxy"]},
      proxies: [],
      capabilities_required: ["session:default/create"],
      params: []
    }

    :ok = AgentKindRegistry.register("claude_code", "cc", spec)

    assert {:ok, ^spec} = AgentKindRegistry.lookup("claude_code.cc")
  end

  test "lookup returns :not_found on miss" do
    assert :not_found = AgentKindRegistry.lookup("nonexistent.kind")
  end

  test "find_unqualified returns single hit, ambiguous, or :not_found" do
    base = %{
      pipeline: %{inbound: [], outbound: []},
      proxies: [],
      capabilities_required: [],
      params: [],
      description: "",
      handler_module: nil
    }

    :ok =
      AgentKindRegistry.register("claude_code", "cc",
        Map.merge(base, %{plugin: "claude_code", name: "cc"})
      )

    assert {:ok, "claude_code.cc", _} = AgentKindRegistry.find_unqualified("cc")
    assert :not_found = AgentKindRegistry.find_unqualified("voice")

    # Two plugins each declaring `cc` → ambiguous
    :ok =
      AgentKindRegistry.register("clone_plugin", "cc",
        Map.merge(base, %{plugin: "clone_plugin", name: "cc"})
      )

    assert {:error, {:ambiguous, keys}} = AgentKindRegistry.find_unqualified("cc")
    assert "claude_code.cc" in keys
    assert "clone_plugin.cc" in keys
  end

  test "list_keys returns every registered key, sorted" do
    base = %{
      pipeline: %{inbound: [], outbound: []},
      proxies: [],
      capabilities_required: [],
      params: [],
      description: "",
      handler_module: nil
    }

    for {p, k} <- [{"plugin_b", "z"}, {"plugin_a", "a"}, {"plugin_a", "b"}] do
      :ok = AgentKindRegistry.register(p, k, Map.merge(base, %{plugin: p, name: k}))
    end

    assert AgentKindRegistry.list_keys() ==
             ["plugin_a.a", "plugin_a.b", "plugin_b.z"]
  end

  test "list_kinds_for_plugin filters by plugin" do
    base = %{
      pipeline: %{inbound: [], outbound: []},
      proxies: [],
      capabilities_required: [],
      params: [],
      description: "",
      handler_module: nil
    }

    :ok = AgentKindRegistry.register("a", "k1", Map.merge(base, %{plugin: "a", name: "k1"}))
    :ok = AgentKindRegistry.register("a", "k2", Map.merge(base, %{plugin: "a", name: "k2"}))
    :ok = AgentKindRegistry.register("b", "k3", Map.merge(base, %{plugin: "b", name: "k3"}))

    keys_a =
      AgentKindRegistry.list_kinds_for_plugin("a")
      |> Enum.map(fn {key, _} -> key end)
      |> Enum.sort()

    assert keys_a == ["a.k1", "a.k2"]
  end
end

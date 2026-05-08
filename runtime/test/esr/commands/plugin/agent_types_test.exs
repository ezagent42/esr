defmodule Esr.Commands.Plugin.AgentTypesTest do
  use ExUnit.Case, async: false

  setup do
    fixture =
      Path.join([__DIR__, "..", "..", "fixtures", "agents", "simple.yaml"])
      |> Path.expand()

    :ok = Esr.Entity.Agent.Registry.load_agents(fixture)
    :ok
  end

  test "lists agent types loaded from agents fixture" do
    cmd = %{"submitted_by" => "linyilun", "args" => %{}}
    assert {:ok, %{"text" => text}} = Esr.Commands.Plugin.AgentTypes.execute(cmd)
    assert text =~ "cc"
  end

  test "empty fixture renders the no-agents message" do
    :ok = Esr.Entity.Agent.Registry.load_agents("/dev/null")
    cmd = %{"submitted_by" => "linyilun", "args" => %{}}
    assert {:ok, %{"text" => text}} = Esr.Commands.Plugin.AgentTypes.execute(cmd)
    assert text =~ "no agents loaded"
  end
end

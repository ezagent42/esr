defmodule Esr.Admin.Commands.Agent.ListTest do
  @moduledoc """
  Tests for `Esr.Admin.Commands.Agent.List` (PR-21κ).

  Loads the `simple.yaml` fixture used by `SessionRegistry`-level tests
  to verify Agent.List surfaces the agent name as a plain text bullet.
  """

  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Agent.List, as: AgentList

  test "lists agents from agents.yaml" do
    fixture = Path.expand("../../../fixtures/agents/simple.yaml", __DIR__)
    :ok = Esr.Entity.Agent.Registry.load_agents(fixture)

    assert {:ok, %{"text" => text}} = AgentList.execute(%{})
    assert text =~ "available agents:"
    assert text =~ "  - cc"
  end

  test "empty agents → 'no agents loaded' text" do
    empty = Path.join(System.tmp_dir!(), "agents-empty-#{System.unique_integer([:positive])}.yaml")
    File.write!(empty, "agents: {}\n")
    :ok = Esr.Entity.Agent.Registry.load_agents(empty)

    assert {:ok, %{"text" => text}} = AgentList.execute(%{})
    assert text =~ "no agents loaded"

    File.rm(empty)
  end
end

defmodule Esr.Commands.Session.AddAgentTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Session.AddAgent

  @sess "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

  setup do
    # Ensure InstanceRegistry is running for tests.
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    # Load agents fixture so "cc" is a known type in all tests.
    fixture =
      Path.join([
        __DIR__,
        "..",
        "..",
        "fixtures",
        "agents",
        "simple.yaml"
      ])
      |> Path.expand()

    :ok = Esr.Entity.Agent.Registry.load_agents(fixture)
    :ok
  end

  test "success: adds agent to session" do
    name = "dev-#{:rand.uniform(9999)}"
    cmd = %{"args" => %{"session_id" => @sess, "type" => "cc", "name" => name, "config" => %{}}}
    assert {:ok, result} = AddAgent.execute(cmd)
    assert result["action"] == "added"
    assert result["type"] == "cc"
  end

  test "error: duplicate name returns structured error" do
    name = "dup-#{:rand.uniform(9999)}"
    sess = "f0e1d2c3-b4a5-4968-8765-432109abcdef"
    cmd = %{"args" => %{"session_id" => sess, "type" => "cc", "name" => name, "config" => %{}}}
    {:ok, _} = AddAgent.execute(cmd)
    assert {:error, %{"type" => "duplicate_agent_name"}} = AddAgent.execute(cmd)
  end

  test "error: missing session_id" do
    cmd = %{"args" => %{"type" => "cc", "name" => "dev"}}
    assert {:error, %{"type" => "invalid_args"}} = AddAgent.execute(cmd)
  end

  test "error: missing name" do
    cmd = %{"args" => %{"session_id" => @sess, "type" => "cc"}}
    assert {:error, %{"type" => "invalid_args"}} = AddAgent.execute(cmd)
  end

  test "error: missing type" do
    cmd = %{"args" => %{"session_id" => @sess, "name" => "dev"}}
    assert {:error, %{"type" => "invalid_args"}} = AddAgent.execute(cmd)
  end

  describe "plugin type validation" do
    test "type declared in enabled plugin manifest is accepted" do
      # "cc" is the claude_code plugin type — declared in agents.yaml / plugin manifest.
      cmd = %{"args" => %{"session_id" => @sess, "type" => "cc", "name" => "valid-#{:rand.uniform(9999)}", "config" => %{}}}
      assert {:ok, _} = AddAgent.execute(cmd)
    end

    test "type not declared in any enabled plugin is rejected" do
      cmd = %{"args" => %{"session_id" => @sess, "type" => "nonexistent_type_xyz", "name" => "x-#{:rand.uniform(9999)}", "config" => %{}}}
      assert {:error, %{"type" => "unknown_agent_type"}} = AddAgent.execute(cmd)
    end
  end
end

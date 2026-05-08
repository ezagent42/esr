defmodule Esr.Commands.Agent.AddTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Agent.Add

  @sess "11111111-1111-4111-8111-aaaaaaaaaaaa"

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    fixture =
      Path.join([__DIR__, "..", "..", "fixtures", "agents", "simple.yaml"])
      |> Path.expand()

    :ok = Esr.Entity.Agent.Registry.load_agents(fixture)
    :ok
  end

  test "without a running Scope: returns structured spawn_failed error" do
    name = "dev-#{:rand.uniform(9999)}"
    cmd = %{"args" => %{"session_id" => @sess, "type" => "cc", "name" => name, "config" => %{}}}
    assert {:error, %{"type" => "spawn_failed"}} = Add.execute(cmd)
  end

  test "missing session_id: returns invalid_args" do
    assert {:error, %{"type" => "invalid_args"}} =
             Add.execute(%{"args" => %{"type" => "cc", "name" => "x"}})
  end

  test "unknown agent type: returns unknown_agent_type" do
    cmd = %{"args" => %{"session_id" => @sess, "type" => "no_such", "name" => "x", "config" => %{}}}
    assert {:error, %{"type" => "unknown_agent_type"}} = Add.execute(cmd)
  end
end

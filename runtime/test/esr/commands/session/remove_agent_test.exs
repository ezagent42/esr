defmodule Esr.Commands.Session.RemoveAgentTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Session.{RemoveAgent, SetPrimary}
  alias Esr.Entity.Agent.InstanceRegistry

  @sess "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"

  # M-2.8: seed agents via the legacy add_instance/2 (metadata-only) API
  # since AddAgent.execute now goes through add_instance_and_spawn which
  # requires a per-session AgentSupervisor not available in this unit
  # test. The remove/set-primary control-plane logic does not depend on
  # the spawned subtree existing.
  defp seed_agent(sess, name) do
    :ok =
      InstanceRegistry.add_instance(%{
        session_id: sess,
        type: "cc",
        name: name,
        config: %{}
      })
  end

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    # Load agents fixture so "cc" is a known type.
    fixture =
      Path.join([__DIR__, "..", "..", "fixtures", "agents", "simple.yaml"])
      |> Path.expand()

    :ok = Esr.Entity.Agent.Registry.load_agents(fixture)
    :ok
  end

  test "success: removes a non-primary agent" do
    alice = "alice-#{:rand.uniform(9999)}"
    bob = "bob-#{:rand.uniform(9999)}"
    # Use a unique session to avoid state pollution from other tests.
    sess = "c3d4e5f6-a7b8-4c9d-0e1f-#{Integer.to_string(:rand.uniform(999_999_999_999)) |> String.pad_leading(12, "0")}"

    seed_agent(sess, alice)
    seed_agent(sess, bob)
    SetPrimary.execute(%{"args" => %{"session_id" => sess, "name" => bob}})

    assert {:ok, %{"action" => "removed"}} =
             RemoveAgent.execute(%{"args" => %{"session_id" => sess, "name" => alice}})
  end

  test "error: cannot remove primary agent" do
    name = "primary-#{:rand.uniform(9999)}"
    sess = "d4e5f6a7-b8c9-4d0e-1f2a-#{Integer.to_string(:rand.uniform(999_999_999_999)) |> String.pad_leading(12, "0")}"
    seed_agent(sess, name)

    assert {:error, %{"type" => "cannot_remove_primary"}} =
             RemoveAgent.execute(%{"args" => %{"session_id" => sess, "name" => name}})
  end

  test "error: unknown agent name" do
    assert {:error, %{"type" => "not_found"}} =
             RemoveAgent.execute(%{"args" => %{"session_id" => @sess, "name" => "ghost-#{:rand.uniform(9999)}"}})
  end

  test "error: missing session_id" do
    assert {:error, %{"type" => "invalid_args"}} =
             RemoveAgent.execute(%{"args" => %{"name" => "dev"}})
  end
end

defmodule Esr.Commands.Agent.SetPrimaryTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Agent.SetPrimary
  alias Esr.Entity.Agent.InstanceRegistry

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

    # Phase 6 (2026-05-10): the legacy `Esr.Entity.Agent.Registry`
    # agents.yaml fixture-load was dead weight here — SetPrimary
    # operates on `Esr.Entity.Agent.InstanceRegistry` and does no
    # agent_kind lookup at all.
    :ok
  end

  test "success: changes primary agent" do
    sess = "e5f6a7b8-c9d0-4e1f-2a3b-#{Integer.to_string(:rand.uniform(999_999_999_999)) |> String.pad_leading(12, "0")}"
    alice = "alice-#{:rand.uniform(9999)}"
    bob = "bob-#{:rand.uniform(9999)}"

    seed_agent(sess, alice)
    seed_agent(sess, bob)

    assert {:ok, %{"action" => "primary_set", "primary_agent" => ^bob}} =
             SetPrimary.execute(%{"args" => %{"session_id" => sess, "name" => bob}})
  end

  test "error: unknown agent name" do
    sess = "f6a7b8c9-d0e1-4f2a-3b4c-#{Integer.to_string(:rand.uniform(999_999_999_999)) |> String.pad_leading(12, "0")}"
    assert {:error, %{"type" => "not_found"}} =
             SetPrimary.execute(%{"args" => %{"session_id" => sess, "name" => "ghost"}})
  end

  test "error: missing session_id" do
    assert {:error, %{"type" => "invalid_args"}} =
             SetPrimary.execute(%{"args" => %{"name" => "dev"}})
  end

  test "error: missing name" do
    assert {:error, %{"type" => "invalid_args"}} =
             SetPrimary.execute(%{"args" => %{"session_id" => "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"}})
  end
end

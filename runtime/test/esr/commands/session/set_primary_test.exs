defmodule Esr.Commands.Session.SetPrimaryTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Session.{AddAgent, SetPrimary}

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

  test "success: changes primary agent" do
    sess = "e5f6a7b8-c9d0-4e1f-2a3b-#{Integer.to_string(:rand.uniform(999_999_999_999)) |> String.pad_leading(12, "0")}"
    alice = "alice-#{:rand.uniform(9999)}"
    bob = "bob-#{:rand.uniform(9999)}"

    AddAgent.execute(%{"args" => %{"session_id" => sess, "type" => "cc", "name" => alice, "config" => %{}}})
    AddAgent.execute(%{"args" => %{"session_id" => sess, "type" => "cc", "name" => bob, "config" => %{}}})

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

  # ---------------------------------------------------------------------------
  # Phase 4.3 — lifecycle: SetPrimary → resolve_routing uses new primary
  # ---------------------------------------------------------------------------

  describe "lifecycle: set_primary → resolve_routing routes to new primary" do
    test "next plain text routes to newly-set primary" do
      sess = "c3d4e5f6-a7b8-4c9d-0e1f-#{Integer.to_string(:rand.uniform(999_999_999_999)) |> String.pad_leading(12, "0")}"
      alice = "routing-alice-#{:rand.uniform(9999)}"
      bob = "routing-bob-#{:rand.uniform(9999)}"

      {:ok, _} = AddAgent.execute(%{
        "args" => %{"session_id" => sess, "type" => "cc", "name" => alice, "config" => %{}}
      })
      {:ok, _} = AddAgent.execute(%{
        "args" => %{"session_id" => sess, "type" => "cc", "name" => bob, "config" => %{}}
      })

      # alice is primary (first added); plain text routes to alice.
      assert {:primary, ^alice} = Esr.Entity.SlashHandler.resolve_routing("hello", sess)

      # Promote bob.
      {:ok, _} = SetPrimary.execute(%{
        "args" => %{"session_id" => sess, "name" => bob}
      })

      # Now plain text routes to bob.
      assert {:primary, ^bob} = Esr.Entity.SlashHandler.resolve_routing("hello again", sess)
    end
  end
end

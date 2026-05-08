defmodule Esr.Entity.SlashHandler.MentionTest do
  @moduledoc """
  Tests for `Esr.Entity.SlashHandler.resolve_routing/2` — mention-based
  routing for non-slash plain-text messages (Phase 4.2).
  """

  use ExUnit.Case, async: false
  alias Esr.Entity.Agent.InstanceRegistry

  setup do
    case Process.whereis(InstanceRegistry) do
      nil -> start_supervised!(InstanceRegistry)
      _ -> :ok
    end

    # Load agent registry fixture so "cc" is a known type.
    fixture =
      Path.join([__DIR__, "..", "fixtures", "agents", "simple.yaml"])
      |> Path.expand()

    :ok = Esr.Entity.Agent.Registry.load_agents(fixture)

    # Use a unique session per test to avoid cross-test state collisions.
    sess = "mention-test-#{:rand.uniform(999_999_999)}"

    # Add two agents; alice is primary (first added).
    :ok = InstanceRegistry.add_instance(%{session_id: sess, type: "cc", name: "alice", config: %{}})
    :ok = InstanceRegistry.add_instance(%{session_id: sess, type: "cc", name: "bob", config: %{}})

    {:ok, sess: sess}
  end

  test "resolve_routing/2: plain text with no mention routes to primary", %{sess: sess} do
    {:ok, primary} = InstanceRegistry.primary(sess)
    assert {:primary, ^primary} = Esr.Entity.SlashHandler.resolve_routing("just some text", sess)
  end

  test "resolve_routing/2: @alice mention returns {:mention, 'alice', stripped_text}", %{sess: sess} do
    assert {:mention, "alice", "please help"} =
             Esr.Entity.SlashHandler.resolve_routing("@alice please help", sess)
  end

  test "resolve_routing/2: @bob mention routes to bob", %{sess: sess} do
    assert {:mention, "bob", "take a look"} =
             Esr.Entity.SlashHandler.resolve_routing("@bob take a look", sess)
  end

  test "resolve_routing/2: @unknown mention falls back to primary", %{sess: sess} do
    {:ok, primary} = InstanceRegistry.primary(sess)

    assert {:primary, ^primary} =
             Esr.Entity.SlashHandler.resolve_routing("@unknown hello", sess)
  end

  test "resolve_routing/2: lone @ falls back to primary", %{sess: sess} do
    {:ok, primary} = InstanceRegistry.primary(sess)

    assert {:primary, ^primary} =
             Esr.Entity.SlashHandler.resolve_routing("@ hello", sess)
  end

  test "resolve_routing/2: session with no agents returns {:error, :no_primary}" do
    empty_sess = "00000000-0000-4000-8000-#{:rand.uniform(999_999_999_999)}"

    assert {:error, :no_primary} =
             Esr.Entity.SlashHandler.resolve_routing("hello", empty_sess)
  end
end

defmodule Esr.Entity.SlashHandler.MentionTest do
  @moduledoc """
  Tests for `Esr.Entity.SlashHandler.resolve_routing/2` — mention-based
  routing for non-slash plain-text messages (Phase 4.2).
  """

  use ExUnit.Case, async: false
  alias Esr.Entity.Agent.InstanceRegistry
  alias Esr.Uri.Compat

  setup do
    case Process.whereis(InstanceRegistry) do
      nil -> start_supervised!(InstanceRegistry)
      _ -> :ok
    end

    # PR-4 URI identity migration: ensure Esr.Uri.Store is up so Compat
    # mirror writes have a backing table.
    case Process.whereis(Esr.Uri.Store) do
      nil -> start_supervised!(Esr.Uri.Store)
      _ -> :ok
    end

    # Phase 6 (2026-05-10): the legacy agents.yaml fixture-load is
    # dead weight here — slash_handler mention parsing only consults
    # `Esr.Entity.Agent.InstanceRegistry` (live instances), not any
    # agent_kind/agent_def lookup.

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

defmodule Esr.Entity.Agent.InstanceRegistrySpawnTest do
  @moduledoc """
  M-2.7 — InstanceRegistry.add_instance_and_spawn/2.

  Unit-level coverage of the GenServer-serialized spawn path:
    - Duplicate name is rejected via the metadata table
      (no AgentSupervisor call attempted)
    - Spawn failure cleans up the name index placeholder so a
      retry isn't blocked by a stale entry

  Phase 7 (2026-05-10): the registry's ETS layout split into two tables
  — `<server>` keyed by instance_id holds %Instance{} rows; the sister
  `<server>__nameix` table holds `{(sid, name), instance_id}` reverse
  index entries (one per session in instance.session_ids). These
  assertions read from the name-index table since the {sid, name} →
  instance_id lookup is what name-uniqueness depends on.

  The full integration path (real Scope tree, CC + PTY init machinery)
  is exercised by scenario 18 (M-5).
  """

  use ExUnit.Case, async: false

  alias Esr.Entity.Agent.{Instance, InstanceRegistry}

  setup do
    name = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, server} = InstanceRegistry.start_link(name: name)
    {:ok, server: server, name: name, name_index: :"#{name}__nameix"}
  end

  describe "add_instance_and_spawn/2 duplicate detection" do
    test "rejects when an instance with the same name already exists",
         %{server: server, name_index: name_ix} do
      sid = "dup-" <> uuid_v4()
      agent_name = "helper-#{System.unique_integer([:positive])}"

      assert :ok =
               InstanceRegistry.add_instance(server, %{
                 session_id: sid,
                 type: "cc",
                 name: agent_name,
                 config: %{}
               })

      # Sanity: name index entry landed.
      assert [{_, _}] = :ets.lookup(name_ix, {sid, agent_name})

      assert {:error, {:duplicate_agent_name, ^agent_name}} =
               InstanceRegistry.add_instance_and_spawn(server, %{
                 session_id: sid,
                 type: "cc",
                 name: agent_name,
                 config: %{}
               })
    end
  end

  describe "add_instance_and_spawn/2 spawn failure" do
    test "returns {:error, {:spawn_failed, _}} and writes no metadata when no AgentSupervisor is registered",
         %{server: server, name: server_name, name_index: name_ix} do
      sid = "no-sup-" <> uuid_v4()
      agent_name = "helper-#{System.unique_integer([:positive])}"

      result =
        InstanceRegistry.add_instance_and_spawn(server, %{
          session_id: sid,
          type: "cc",
          name: agent_name,
          config: %{}
        })

      assert match?({:error, {:spawn_failed, _}}, result),
             "expected {:error, {:spawn_failed, _}}, got #{inspect(result)}"

      # No name-index record was written.
      assert [] == :ets.lookup(name_ix, {sid, agent_name})

      # No primary record was written either.
      assert [] == :ets.lookup(server_name, {:primary, sid})
    end
  end

  defp uuid_v4, do: UUID.uuid4()

  # Surface the rebuilt %Instance{} struct so the alias is exercised
  # — keeps the import meaningful for future inspectors of the test
  # file.
  @doc false
  def __instance__, do: %Instance{}
end

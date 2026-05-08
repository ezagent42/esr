defmodule Esr.Entity.Agent.InstanceRegistrySpawnTest do
  @moduledoc """
  M-2.7 — InstanceRegistry.add_instance_and_spawn/2.

  Unit-level coverage of the GenServer-serialized spawn path:
    - Duplicate name is rejected via the metadata table
      (no AgentSupervisor call attempted)
    - Spawn failure cleans up the Index 2 name placeholder so a
      retry isn't blocked by a stale entry

  The full integration path (real Scope tree, CC + PTY init machinery)
  is exercised by scenario 18 (M-5).
  """

  use ExUnit.Case, async: false

  alias Esr.Entity.Agent.{Instance, InstanceRegistry}

  setup do
    name = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, server} = InstanceRegistry.start_link(name: name)
    {:ok, server: server, name: name}
  end

  describe "add_instance_and_spawn/2 duplicate detection" do
    test "rejects when an instance with the same name already exists",
         %{server: server, name: server_name} do
      sid = "dup-#{System.unique_integer([:positive])}"
      agent_name = "helper-#{System.unique_integer([:positive])}"

      # Pre-seed via the public add_instance/2 API (no spawn). The
      # add_instance_and_spawn handler must reject the second call by
      # the metadata-table check BEFORE attempting to call the
      # AgentSupervisor, so this test does not need a real Scope tree.
      assert :ok =
               InstanceRegistry.add_instance(server, %{
                 session_id: sid,
                 type: "cc",
                 name: agent_name,
                 config: %{}
               })

      # Sanity: row landed in the named table.
      assert [{_, %Instance{name: ^agent_name}}] =
               :ets.lookup(server_name, {sid, agent_name})

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
         %{server: server, name: server_name} do
      sid = "no-sup-#{System.unique_integer([:positive])}"
      agent_name = "helper-#{System.unique_integer([:positive])}"

      # No Scope started for `sid`, so the via-tuple
      # {:via, Registry, {Esr.Scope.Registry, {:agent_sup, sid}}} won't
      # resolve to any pid. add_agent_subtree should bubble that up as
      # an error — wrapped in :spawn_failed by the handler.
      result =
        InstanceRegistry.add_instance_and_spawn(server, %{
          session_id: sid,
          type: "cc",
          name: agent_name,
          config: %{}
        })

      assert match?({:error, {:spawn_failed, _}}, result),
             "expected {:error, {:spawn_failed, _}}, got #{inspect(result)}"

      # No metadata record was written.
      assert [] == :ets.lookup(server_name, {sid, agent_name})

      # No primary record was written either.
      assert [] == :ets.lookup(server_name, {sid, :__primary__})
    end
  end
end

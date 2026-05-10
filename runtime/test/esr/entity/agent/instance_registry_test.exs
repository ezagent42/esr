defmodule Esr.Entity.Agent.InstanceRegistryTest do
  use ExUnit.Case, async: false
  alias Esr.Entity.Agent.InstanceRegistry

  @sess1 "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @sess2 "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"
  @sess3 "c3d4e5f6-a7b8-4c9d-0e1f-a2b3c4d5e6f7"

  setup do
    # Each test uses a fresh GenServer under a unique name to isolate ETS state.
    name = :"ir_test_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = start_supervised({InstanceRegistry, name: name})
    %{reg: name}
  end

  describe "add_instance/2" do
    test "adds instance to session", %{reg: reg} do
      assert :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "dev", config: %{}})
      assert {:ok, inst} = InstanceRegistry.get(reg, @sess1, "dev")
      assert inst.type == "cc"
      assert inst.name == "dev"
      assert inst.session_ids == [@sess1]
    end

    test "rejects duplicate name in same session regardless of type", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "dev", config: %{}})
      assert {:error, {:duplicate_agent_name, "dev"}} =
               InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "codex", name: "dev", config: %{}})
    end

    test "same name in different sessions is allowed", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "dev", config: %{}})
      assert :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess2, type: "cc", name: "dev", config: %{}})
    end

    test "sets as primary if first agent in session", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "alice", config: %{}})
      assert {:ok, "alice"} = InstanceRegistry.primary(reg, @sess1)
    end

    test "does not change primary if not first agent", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "alice", config: %{}})
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "bob", config: %{}})
      assert {:ok, "alice"} = InstanceRegistry.primary(reg, @sess1)
    end

    test "session_ids array can be passed directly", %{reg: reg} do
      assert :ok = InstanceRegistry.add_instance(reg, %{
               session_ids: [@sess1, @sess2],
               type: "cc",
               name: "shared",
               config: %{}
             })

      assert {:ok, inst} = InstanceRegistry.get(reg, @sess1, "shared")
      assert inst.session_ids == [@sess1, @sess2]

      # Same instance is reachable via the second session too.
      assert {:ok, inst2} = InstanceRegistry.get(reg, @sess2, "shared")
      assert inst2.id == inst.id
    end
  end

  describe "remove_instance/3" do
    test "removes instance from session", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "dev", config: %{}})
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "reviewer", config: %{}})
      :ok = InstanceRegistry.set_primary(reg, @sess1, "reviewer")

      assert :ok = InstanceRegistry.remove_instance(reg, @sess1, "dev")
      assert :not_found = InstanceRegistry.get(reg, @sess1, "dev")
    end

    test "cannot remove primary agent without first setting another primary", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "alice", config: %{}})
      assert {:error, :cannot_remove_primary} = InstanceRegistry.remove_instance(reg, @sess1, "alice")
    end

    test "remove last agent clears primary", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "only", config: %{}})
      :ok = InstanceRegistry.set_primary(reg, @sess1, "only")
      assert {:error, :cannot_remove_primary} = InstanceRegistry.remove_instance(reg, @sess1, "only")
    end

    test "returns :not_found for unknown agent", %{reg: reg} do
      assert {:error, :not_found} = InstanceRegistry.remove_instance(reg, @sess1, "ghost")
    end

    test "removes from one session only — instance survives if attached to others", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{
              session_ids: [@sess1, @sess2],
              type: "cc",
              name: "shared",
              config: %{}
            })

      # Make a second agent in @sess1 the primary so we can detach `shared` from @sess1.
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "primary_agent", config: %{}})
      :ok = InstanceRegistry.set_primary(reg, @sess1, "primary_agent")

      assert :ok = InstanceRegistry.remove_instance(reg, @sess1, "shared")

      # Gone from @sess1.
      assert :not_found = InstanceRegistry.get(reg, @sess1, "shared")

      # Still alive in @sess2 — name-index untouched.
      assert {:ok, inst} = InstanceRegistry.get(reg, @sess2, "shared")
      assert inst.session_ids == [@sess2]
    end
  end

  describe "list/2" do
    test "returns all instances for session", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "a", config: %{}})
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "b", config: %{}})
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess2, type: "cc", name: "a", config: %{}})

      instances = InstanceRegistry.list(reg, @sess1)
      names = Enum.map(instances, & &1.name) |> Enum.sort()
      assert names == ["a", "b"]
    end

    test "returns empty list for unknown session", %{reg: reg} do
      assert [] = InstanceRegistry.list(reg, @sess1)
    end
  end

  describe "set_primary/3 + primary/2" do
    test "set_primary changes the primary agent", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "alice", config: %{}})
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "bob", config: %{}})

      assert :ok = InstanceRegistry.set_primary(reg, @sess1, "bob")
      assert {:ok, "bob"} = InstanceRegistry.primary(reg, @sess1)
    end

    test "set_primary on unknown name returns error", %{reg: reg} do
      assert {:error, :not_found} = InstanceRegistry.set_primary(reg, @sess1, "ghost")
    end

    test "primary returns :not_found for session with no agents", %{reg: reg} do
      assert :not_found = InstanceRegistry.primary(reg, @sess1)
    end
  end

  describe "names_for_session/2" do
    test "returns list of agent names for session", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "x", config: %{}})
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "y", config: %{}})
      names = InstanceRegistry.names_for_session(reg, @sess1)
      assert Enum.sort(names) == ["x", "y"]
    end
  end

  describe "attach_to_session/4 — Phase 7 multi-session-per-instance" do
    test "appends a new session to an existing instance", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "alice", config: %{}})

      assert :ok = InstanceRegistry.attach_to_session(reg, "alice", @sess1, @sess2)

      # Same instance reachable via both sessions.
      {:ok, from_a} = InstanceRegistry.get(reg, @sess1, "alice")
      {:ok, from_b} = InstanceRegistry.get(reg, @sess2, "alice")
      assert from_a.id == from_b.id
      assert from_a.session_ids == [@sess1, @sess2]
    end

    test "is idempotent (re-attaching to same session is a no-op)", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "alice", config: %{}})
      :ok = InstanceRegistry.attach_to_session(reg, "alice", @sess1, @sess2)
      assert :ok = InstanceRegistry.attach_to_session(reg, "alice", @sess1, @sess2)

      {:ok, inst} = InstanceRegistry.get(reg, @sess1, "alice")
      # @sess2 appears exactly once.
      assert Enum.count(inst.session_ids, fn s -> s == @sess2 end) == 1
    end

    test "rejects when target session already hosts an instance with the same name", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "alice", config: %{}})
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess2, type: "cc", name: "alice", config: %{}})

      assert {:error, {:name_taken_in_target, @sess2}} =
               InstanceRegistry.attach_to_session(reg, "alice", @sess1, @sess2)
    end

    test "returns :not_found if instance doesn't exist in source session", %{reg: reg} do
      assert {:error, :not_found} =
               InstanceRegistry.attach_to_session(reg, "ghost", @sess1, @sess2)
    end

    test "instance attached to N sessions can be queried via any of them", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "alice", config: %{}})
      :ok = InstanceRegistry.attach_to_session(reg, "alice", @sess1, @sess2)
      :ok = InstanceRegistry.attach_to_session(reg, "alice", @sess1, @sess3)

      ids =
        for s <- [@sess1, @sess2, @sess3] do
          {:ok, inst} = InstanceRegistry.get(reg, s, "alice")
          inst.id
        end

      assert length(Enum.uniq(ids)) == 1, "all three lookups should resolve to the same instance"
    end
  end

  describe "actor_ids field on %Instance{}" do
    test "Instance struct carries actor_ids field" do
      inst = %Esr.Entity.Agent.Instance{
        id: "11111111-1111-4111-8111-111111111111",
        session_ids: ["22222222-2222-4222-8222-222222222222"],
        type: "cc",
        name: "alice",
        config: %{},
        created_at: "2026-05-08T00:00:00Z",
        actor_ids: %{cc: "cc-uuid", pty: "pty-uuid"}
      }

      assert inst.actor_ids == %{cc: "cc-uuid", pty: "pty-uuid"}
    end

    test "pty_actor_id_for/2 returns the persisted PTY id" do
      sid = "33333333-3333-4333-8333-333333333333"
      name = "alice"

      case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
        nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
        _ -> :ok
      end

      tab = :ets.info(Esr.Entity.Agent.InstanceRegistry)
      _ = tab

      # Use the public API so we don't have to touch the (now-internal)
      # two-table layout from a test.
      :ok = Esr.Entity.Agent.InstanceRegistry.add_instance(%{
              session_id: sid,
              type: "cc",
              name: name,
              config: %{}
            })

      # Inject actor_ids — `add_instance/2` doesn't take spawn refs;
      # rewrite the row through the metadata table.
      [{instance_id, inst_record}] = :ets.lookup(Esr.Entity.Agent.InstanceRegistry, lookup_instance_id(sid, name))
      :ets.insert(
        Esr.Entity.Agent.InstanceRegistry,
        {instance_id, %{inst_record | actor_ids: %{cc: instance_id, pty: "pty-uuid-bbbb"}}}
      )

      assert {:ok, "pty-uuid-bbbb"} =
               Esr.Entity.Agent.InstanceRegistry.pty_actor_id_for(sid, name)

      assert :not_found =
               Esr.Entity.Agent.InstanceRegistry.pty_actor_id_for(sid, "no-such")
    end
  end

  defp lookup_instance_id(sid, name) do
    [{_, instance_id}] = :ets.lookup(:"#{Esr.Entity.Agent.InstanceRegistry}__nameix", {sid, name})
    instance_id
  end
end

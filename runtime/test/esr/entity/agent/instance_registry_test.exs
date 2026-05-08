defmodule Esr.Entity.Agent.InstanceRegistryTest do
  use ExUnit.Case, async: false
  alias Esr.Entity.Agent.InstanceRegistry

  @sess1 "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @sess2 "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"

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
      # Must set_primary to something else first — but there is nothing else.
      # This tests that remove guard fires correctly.
      assert {:error, :cannot_remove_primary} = InstanceRegistry.remove_instance(reg, @sess1, "only")
    end

    test "returns :not_found for unknown agent", %{reg: reg} do
      assert {:error, :not_found} = InstanceRegistry.remove_instance(reg, @sess1, "ghost")
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
end

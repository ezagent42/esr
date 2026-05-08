defmodule Esr.Commands.Agent.RenameTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Agent.Rename

  @sess "77777777-7777-4777-8777-777777777777"

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    :ok
  end

  test "missing args: returns invalid_args" do
    assert {:error, %{"type" => "invalid_args"}} =
             Rename.execute(%{"args" => %{"session_id" => @sess}})
  end

  test "renames an existing instance" do
    tab = GenServer.call(Esr.Entity.Agent.InstanceRegistry, :table_name)

    inst = %Esr.Entity.Agent.Instance{
      id: "cc-uuid-r",
      session_id: @sess,
      type: "cc",
      name: "alice",
      config: %{},
      created_at: "2026-05-08T00:00:00Z",
      actor_ids: %{cc: "cc-uuid-r", pty: "pty-uuid-r"}
    }

    :ets.insert(tab, {{@sess, "alice"}, inst})

    cmd = %{"args" => %{"session_id" => @sess, "name" => "alice", "new_name" => "alicia"}}

    assert {:ok, %{"action" => "renamed", "old_name" => "alice", "new_name" => "alicia"}} =
             Rename.execute(cmd)

    assert :not_found = Esr.Entity.Agent.InstanceRegistry.get(@sess, "alice")
    assert {:ok, _} = Esr.Entity.Agent.InstanceRegistry.get(@sess, "alicia")
  end

  test "name collision: returns duplicate_agent_name" do
    tab = GenServer.call(Esr.Entity.Agent.InstanceRegistry, :table_name)
    sid = "88888888-8888-4888-8888-888888888888"

    inst_a = %Esr.Entity.Agent.Instance{id: "a", session_id: sid, type: "cc", name: "x", config: %{}, created_at: "t", actor_ids: %{cc: "a", pty: "ap"}}
    inst_b = %Esr.Entity.Agent.Instance{id: "b", session_id: sid, type: "cc", name: "y", config: %{}, created_at: "t", actor_ids: %{cc: "b", pty: "bp"}}

    :ets.insert(tab, {{sid, "x"}, inst_a})
    :ets.insert(tab, {{sid, "y"}, inst_b})

    cmd = %{"args" => %{"session_id" => sid, "name" => "x", "new_name" => "y"}}
    assert {:error, %{"type" => "duplicate_agent_name"}} = Rename.execute(cmd)
  end

  test "rename non-existent agent: returns not_found" do
    sid = "99999999-9999-4999-8999-999999999999"
    cmd = %{"args" => %{"session_id" => sid, "name" => "ghost", "new_name" => "phantom"}}
    assert {:error, %{"type" => "not_found"}} = Rename.execute(cmd)
  end

  test "rename to same name: returns ok with no-op semantics" do
    tab = GenServer.call(Esr.Entity.Agent.InstanceRegistry, :table_name)
    sid = "aaaaaaaa-9999-4999-8999-aaaaaaaaaaaa"

    inst = %Esr.Entity.Agent.Instance{
      id: "cc-noop",
      session_id: sid,
      type: "cc",
      name: "alice",
      config: %{},
      created_at: "2026-05-08T00:00:00Z",
      actor_ids: %{cc: "cc-noop", pty: "pty-noop"}
    }

    :ets.insert(tab, {{sid, "alice"}, inst})

    cmd = %{"args" => %{"session_id" => sid, "name" => "alice", "new_name" => "alice"}}
    assert {:ok, %{"action" => "renamed", "old_name" => "alice", "new_name" => "alice"}} =
             Rename.execute(cmd)

    # Row still present unchanged
    assert {:ok, %Esr.Entity.Agent.Instance{name: "alice"}} =
             Esr.Entity.Agent.InstanceRegistry.get(sid, "alice")
  end
end

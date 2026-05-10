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
    :ok = Esr.Entity.Agent.InstanceRegistry.add_instance(%{
            session_id: @sess,
            type: "cc",
            name: "alice",
            config: %{}
          })

    cmd = %{"args" => %{"session_id" => @sess, "name" => "alice", "new_name" => "alicia"}}

    assert {:ok, %{"action" => "renamed", "old_name" => "alice", "new_name" => "alicia"}} =
             Rename.execute(cmd)

    assert :not_found = Esr.Entity.Agent.InstanceRegistry.get(@sess, "alice")
    assert {:ok, _} = Esr.Entity.Agent.InstanceRegistry.get(@sess, "alicia")
  end

  test "name collision: returns duplicate_agent_name" do
    sid = "88888888-8888-4888-8888-888888888888"

    :ok = Esr.Entity.Agent.InstanceRegistry.add_instance(%{
            session_id: sid, type: "cc", name: "x", config: %{}
          })
    :ok = Esr.Entity.Agent.InstanceRegistry.add_instance(%{
            session_id: sid, type: "cc", name: "y", config: %{}
          })

    cmd = %{"args" => %{"session_id" => sid, "name" => "x", "new_name" => "y"}}
    assert {:error, %{"type" => "duplicate_agent_name"}} = Rename.execute(cmd)
  end

  test "rename non-existent agent: returns not_found" do
    sid = "99999999-9999-4999-8999-999999999999"
    cmd = %{"args" => %{"session_id" => sid, "name" => "ghost", "new_name" => "phantom"}}
    assert {:error, %{"type" => "not_found"}} = Rename.execute(cmd)
  end

  test "rename to same name: returns ok with no-op semantics" do
    sid = "aaaaaaaa-9999-4999-8999-aaaaaaaaaaaa"

    :ok = Esr.Entity.Agent.InstanceRegistry.add_instance(%{
            session_id: sid, type: "cc", name: "alice", config: %{}
          })

    cmd = %{"args" => %{"session_id" => sid, "name" => "alice", "new_name" => "alice"}}
    assert {:ok, %{"action" => "renamed", "old_name" => "alice", "new_name" => "alice"}} =
             Rename.execute(cmd)

    # Row still present unchanged
    assert {:ok, %Esr.Entity.Agent.Instance{name: "alice"}} =
             Esr.Entity.Agent.InstanceRegistry.get(sid, "alice")
  end
end

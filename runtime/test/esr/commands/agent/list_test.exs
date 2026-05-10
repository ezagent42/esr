defmodule Esr.Commands.Agent.ListTest do
  use ExUnit.Case, async: false

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    case Process.whereis(Esr.Session.ChatRouting.Registry) do
      nil -> start_supervised!(Esr.Session.ChatRouting.Registry)
      _ -> :ok
    end

    :ok
  end

  test "lists instances of chat-current session" do
    chat = "oc_b1_list"
    app = "esr_helper_list"
    sid = "cccccccc-3333-4333-8333-333333333333"
    :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid)

    # Phase 7 two-table layout: use public API to seed names, then patch
    # actor_ids onto each metadata-table row directly.
    for {agent_name, pty_id} <- [{"alice", "pty-uuid-a"}, {"bob", "pty-uuid-b"}] do
      :ok = Esr.Entity.Agent.InstanceRegistry.add_instance(%{
              session_id: sid,
              type: "cc",
              name: agent_name,
              config: %{}
            })

      [{_, instance_id}] =
        :ets.lookup(:"#{Esr.Entity.Agent.InstanceRegistry}__nameix", {sid, agent_name})

      [{_, inst_record}] = :ets.lookup(Esr.Entity.Agent.InstanceRegistry, instance_id)

      :ets.insert(
        Esr.Entity.Agent.InstanceRegistry,
        {instance_id, %{inst_record | actor_ids: %{cc: instance_id, pty: pty_id}}}
      )
    end

    cmd = %{
      "submitted_by" => "linyilun",
      "args" => %{"chat_id" => chat, "app_id" => app}
    }

    assert {:ok, %{"agents" => agents}} = Esr.Commands.Agent.List.execute(cmd)
    names = Enum.map(agents, & &1["name"]) |> Enum.sort()
    assert names == ["alice", "bob"]
  end

  test "empty session: returns empty list" do
    chat = "oc_b1_list_empty"
    app = "esr_helper_list_empty"
    sid = "dddddddd-4444-4444-8444-444444444444"
    :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid)

    cmd = %{
      "submitted_by" => "linyilun",
      "args" => %{"chat_id" => chat, "app_id" => app}
    }

    assert {:ok, %{"agents" => []}} = Esr.Commands.Agent.List.execute(cmd)
  end

  test "no chat context: returns invalid_args" do
    cmd = %{"submitted_by" => "linyilun", "args" => %{}}
    assert {:error, %{"type" => "invalid_args"}} = Esr.Commands.Agent.List.execute(cmd)
  end
end

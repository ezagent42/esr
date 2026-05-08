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

    tab = GenServer.call(Esr.Entity.Agent.InstanceRegistry, :table_name)

    inst_a = %Esr.Entity.Agent.Instance{
      id: "cc-uuid-a",
      session_id: sid,
      type: "cc",
      name: "alice",
      config: %{},
      created_at: "2026-05-08T00:00:00Z",
      actor_ids: %{cc: "cc-uuid-a", pty: "pty-uuid-a"}
    }

    inst_b = %Esr.Entity.Agent.Instance{
      id: "cc-uuid-b",
      session_id: sid,
      type: "cc",
      name: "bob",
      config: %{},
      created_at: "2026-05-08T00:00:00Z",
      actor_ids: %{cc: "cc-uuid-b", pty: "pty-uuid-b"}
    }

    :ets.insert(tab, {{sid, "alice"}, inst_a})
    :ets.insert(tab, {{sid, "bob"}, inst_b})

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

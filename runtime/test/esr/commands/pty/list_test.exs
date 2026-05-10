defmodule Esr.Commands.Pty.ListTest do
  @moduledoc """
  `/pty:list` — list PTY actor ids for agents in chat-current session.
  Spec rev-4 §4.2 row `/pty:list`. Phase E task E.1.
  """

  use ExUnit.Case, async: false
  alias Esr.Commands.Pty.List, as: PtyList

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

  test "lists PTY actor ids for chat-current session agents" do
    chat = "oc_b1_pty_a"
    app = "esr_helper_pty_a"
    sid = "99999999-9999-4999-8999-999999999999"
    :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid)

    # Phase 7 layout: use public API to seed, then patch actor_ids onto
    # the metadata-table row directly.
    :ok = Esr.Entity.Agent.InstanceRegistry.add_instance(%{
            session_id: sid,
            type: "cc",
            name: "alice",
            config: %{}
          })

    [{_, instance_id}] =
      :ets.lookup(:"#{Esr.Entity.Agent.InstanceRegistry}__nameix", {sid, "alice"})

    [{_, inst_record}] = :ets.lookup(Esr.Entity.Agent.InstanceRegistry, instance_id)

    :ets.insert(
      Esr.Entity.Agent.InstanceRegistry,
      {instance_id, %{inst_record | actor_ids: %{cc: instance_id, pty: "pty-uuid-pl"}}}
    )

    cmd = %{"submitted_by" => "linyilun", "args" => %{"chat_id" => chat, "app_id" => app}}
    assert {:ok, %{"ptys" => [pty]}} = PtyList.execute(cmd)
    assert pty["agent_name"] == "alice"
    assert pty["pty_actor_id"] == "pty-uuid-pl"
  end

  test "no chat context: invalid_args" do
    assert {:error, %{"type" => "invalid_args"}} =
             PtyList.execute(%{"submitted_by" => "linyilun", "args" => %{}})
  end
end

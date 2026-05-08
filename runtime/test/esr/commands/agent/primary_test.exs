defmodule Esr.Commands.Agent.PrimaryTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Agent.Primary

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

  test "no session attached to chat: returns no_current_session" do
    chat = "oc_b1_prim_a"
    app = "esr_helper_prim_a"

    cmd = %{"submitted_by" => "linyilun", "args" => %{"chat_id" => chat, "app_id" => app}}
    assert {:error, %{"type" => "no_current_session"}} = Primary.execute(cmd)
  end

  test "session has primary: returns name" do
    chat = "oc_b1_prim_b"
    app = "esr_helper_prim_b"
    sid = "66666666-6666-4666-8666-666666666666"
    :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid)

    tab = GenServer.call(Esr.Entity.Agent.InstanceRegistry, :table_name)
    :ets.insert(tab, {{sid, :__primary__}, "alice"})

    cmd = %{"submitted_by" => "linyilun", "args" => %{"chat_id" => chat, "app_id" => app}}
    assert {:ok, %{"primary" => "alice", "session_id" => ^sid}} = Primary.execute(cmd)
  end
end

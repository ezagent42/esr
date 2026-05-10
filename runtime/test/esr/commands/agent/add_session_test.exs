defmodule Esr.Commands.Agent.AddSessionTest do
  @moduledoc """
  Phase 7 (2026-05-10) — `/agent:add-session` extends an existing
  instance to another session.
  """

  use ExUnit.Case, async: false
  alias Esr.Commands.Agent.AddSession

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    case Process.whereis(Esr.Session.ChatRouting.Registry) do
      nil -> start_supervised!(Esr.Session.ChatRouting.Registry)
      _ -> :ok
    end

    # Per-test unique session UUIDs so the global named
    # InstanceRegistry doesn't leak state across tests in this module.
    sess_a = unique_session_uuid()
    sess_b = unique_session_uuid()
    %{sess_a: sess_a, sess_b: sess_b}
  end

  defp unique_session_uuid do
    UUID.uuid4()
  end

  describe "/agent:add-session — happy path" do
    test "attaches an existing instance to another session", %{sess_a: sess_a, sess_b: sess_b} do
      :ok = Esr.Entity.Agent.InstanceRegistry.add_instance(%{
              session_id: sess_a, type: "cc", name: "alice", config: %{}
            })

      cmd = %{
        "args" => %{
          "session" => sess_b,
          "name" => "alice",
          "source_session_id" => sess_a
        }
      }

      assert {:ok, %{"action" => "attached", "name" => "alice"}} = AddSession.execute(cmd)

      # Same instance pid reachable from both.
      {:ok, from_a} = Esr.Entity.Agent.InstanceRegistry.get(sess_a, "alice")
      {:ok, from_b} = Esr.Entity.Agent.InstanceRegistry.get(sess_b, "alice")
      assert from_a.id == from_b.id
      assert from_a.session_ids == [sess_a, sess_b]
    end

    test "uses chat-current session as source when chat envelope is present",
         %{sess_a: sess_a, sess_b: sess_b} do
      chat_id = "oc_chat_addsess_#{System.unique_integer([:positive])}"
      app_id = "feishu_dev_addsess_#{System.unique_integer([:positive])}"
      :ok = Esr.Session.ChatRouting.Registry.attach_session(chat_id, app_id, sess_a)

      :ok = Esr.Entity.Agent.InstanceRegistry.add_instance(%{
              session_id: sess_a, type: "cc", name: "bob", config: %{}
            })

      cmd = %{
        "args" => %{
          "session" => sess_b,
          "name" => "bob",
          "chat_id" => chat_id,
          "app_id" => app_id
        }
      }

      assert {:ok, %{"action" => "attached", "name" => "bob"}} = AddSession.execute(cmd)
    end
  end

  describe "/agent:add-session — error paths" do
    test "no chat-current and no source_session_id → no_source_session",
         %{sess_b: sess_b} do
      cmd = %{"args" => %{"session" => sess_b, "name" => "alice"}}
      assert {:error, %{"type" => "no_source_session"}} = AddSession.execute(cmd)
    end

    test "instance not found in source → instance_not_found",
         %{sess_a: sess_a, sess_b: sess_b} do
      cmd = %{
        "args" => %{
          "session" => sess_b,
          "name" => "ghost",
          "source_session_id" => sess_a
        }
      }

      assert {:error, %{"type" => "instance_not_found"}} = AddSession.execute(cmd)
    end

    test "target session has a different instance with same name → name_taken_in_target",
         %{sess_a: sess_a, sess_b: sess_b} do
      :ok = Esr.Entity.Agent.InstanceRegistry.add_instance(%{
              session_id: sess_a, type: "cc", name: "alice", config: %{}
            })

      :ok = Esr.Entity.Agent.InstanceRegistry.add_instance(%{
              session_id: sess_b, type: "cc", name: "alice", config: %{}
            })

      cmd = %{
        "args" => %{
          "session" => sess_b,
          "name" => "alice",
          "source_session_id" => sess_a
        }
      }

      assert {:error, %{"type" => "name_taken_in_target"}} = AddSession.execute(cmd)
    end

    test "missing args → invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} = AddSession.execute(%{"args" => %{}})
    end
  end
end

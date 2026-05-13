defmodule Esr.Commands.Pty.InputTest do
  @moduledoc """
  Error-path coverage for `/pty:input`. The happy path (write actually
  hits PTY) is covered by the Phase 8.1 integration test — it requires
  a live PtyProcess pid, which is impractical to spawn from a pure-unit
  command test.

  Spec: `docs/superpowers/specs/2026-05-13-cc-channel-stdio-bridge-design.md` §6.5.
  """

  use ExUnit.Case, async: false
  alias Esr.Commands.Pty.Input

  setup do
    case Process.whereis(Esr.Session.ChatRouting.Registry) do
      nil -> start_supervised!(Esr.Session.ChatRouting.Registry)
      _ -> :ok
    end

    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    :ok
  end

  test "chat unbound → no_session_target" do
    cmd = %{
      "submitted_by" => "linyilun",
      "args" => %{
        "chat_id" => "oc_unbound_input_a",
        "app_id" => "esr_input_a",
        "name" => "alice",
        "text" => "hello"
      }
    }

    assert {:error, %{"type" => "no_session_target"}} = Input.execute(cmd)
  end

  test "agent name unknown in session → not_found" do
    chat = "oc_input_b"
    app = "esr_input_b"
    sid = "33333333-cccc-4ccc-8ccc-333333333333"
    :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid)

    cmd = %{
      "submitted_by" => "linyilun",
      "args" => %{
        "chat_id" => chat,
        "app_id" => app,
        "name" => "ghost",
        "text" => "hello"
      }
    }

    assert {:error, %{"type" => "not_found"}} = Input.execute(cmd)
  end

  test "missing text arg → invalid_args" do
    cmd = %{
      "submitted_by" => "linyilun",
      "args" => %{"chat_id" => "c", "app_id" => "a", "name" => "alice"}
    }

    assert {:error, %{"type" => "invalid_args"}} = Input.execute(cmd)
  end

  test "empty text → invalid_args" do
    cmd = %{
      "submitted_by" => "linyilun",
      "args" => %{"chat_id" => "c", "app_id" => "a", "name" => "alice", "text" => ""}
    }

    assert {:error, %{"type" => "invalid_args"}} = Input.execute(cmd)
  end

  test "missing chat context → invalid_args" do
    cmd = %{
      "submitted_by" => "linyilun",
      "args" => %{"name" => "alice", "text" => "hello"}
    }

    assert {:error, %{"type" => "invalid_args"}} = Input.execute(cmd)
  end
end

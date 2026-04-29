defmodule Esr.Peers.SlashHandlerTest do
  use ExUnit.Case, async: false

  alias Esr.Peers.SlashHandler

  setup do
    # Drift from expansion doc: P2-9 added `Esr.AdminSessionProcess` to
    # `Esr.Application`'s tree, so a redundant `start_supervised!` would
    # crash with :already_started. Reuse the app-level process.
    assert is_pid(Process.whereis(Esr.AdminSessionProcess))
    # Stub Esr.Admin.Dispatcher with a process that echoes commands back.
    dispatcher = self()
    Process.register(dispatcher, :test_admin_dispatcher)

    on_exit(fn ->
      if Process.whereis(:test_admin_dispatcher),
        do: Process.unregister(:test_admin_dispatcher)
    end)

    :ok
  end

  test "slash_cmd is parsed and cast to Admin.Dispatcher with correlation ref" do
    {:ok, pid} =
      GenServer.start_link(
        SlashHandler,
        %{
          dispatcher: :test_admin_dispatcher,
          session_id: "admin",
          neighbors: [],
          proxy_ctx: %{}
        }
      )

    reply_to_proxy = self()

    envelope = %{
      "principal_id" => "p_user",
      "payload" => %{"text" => "/list-sessions", "chat_id" => "oc_z"}
    }

    send(pid, {:slash_cmd, envelope, reply_to_proxy})

    assert_receive {:"$gen_cast",
                    {:execute, %{"kind" => "session_list"}, {:reply_to, {:pid, ^pid, _ref}}}},
                   500
  end

  test "command_result from Dispatcher is relayed to the originating FeishuChatProxy as :reply" do
    {:ok, pid} =
      GenServer.start_link(
        SlashHandler,
        %{
          dispatcher: :test_admin_dispatcher,
          session_id: "admin",
          neighbors: [],
          proxy_ctx: %{}
        }
      )

    envelope = %{
      "principal_id" => "p_user",
      "payload" => %{"text" => "/list-sessions", "chat_id" => "oc_z"}
    }

    send(pid, {:slash_cmd, envelope, self()})

    # Capture the ref the handler used
    assert_receive {:"$gen_cast", {:execute, _cmd, {:reply_to, {:pid, ^pid, ref}}}}, 500

    # Simulate Dispatcher's reply
    send(pid, {:command_result, ref, {:ok, %{"branches" => ["main"]}}})

    # SlashHandler should forward as {:reply, text} back to self() (the proxy)
    assert_receive {:reply, text}, 500
    assert text =~ "sessions:"
  end

  test "registers itself in AdminSessionProcess under :slash_handler on init" do
    {:ok, pid} =
      GenServer.start_link(
        SlashHandler,
        %{
          dispatcher: :test_admin_dispatcher,
          session_id: "admin",
          neighbors: [],
          proxy_ctx: %{}
        }
      )

    assert {:ok, ^pid} = Esr.AdminSessionProcess.admin_peer(:slash_handler)
  end

  test "unknown slash text returns :drop and a user-facing error reply" do
    {:ok, pid} =
      GenServer.start_link(
        SlashHandler,
        %{
          dispatcher: :test_admin_dispatcher,
          session_id: "admin",
          neighbors: [],
          proxy_ctx: %{}
        }
      )

    envelope = %{
      "principal_id" => "p_user",
      "payload" => %{"text" => "/completely-unknown foo", "chat_id" => "oc_z"}
    }

    send(pid, {:slash_cmd, envelope, self()})

    assert_receive {:reply, text}, 500
    assert text =~ "unknown command"
  end

  test "new-session (PR-21d) parses workspace name= cwd= worktree= into session_new" do
    {:ok, pid} =
      GenServer.start_link(
        SlashHandler,
        %{
          dispatcher: :test_admin_dispatcher,
          session_id: "admin",
          neighbors: [],
          proxy_ctx: %{}
        }
      )

    envelope = %{
      "principal_id" => "p_user",
      "payload" => %{
        "text" =>
          "/new-session esr-dev name=feature-foo cwd=/tmp/wt worktree=feature-foo",
        "chat_id" => "oc_z"
      }
    }

    send(pid, {:slash_cmd, envelope, self()})

    assert_receive {:"$gen_cast",
                    {:execute,
                     %{
                       "kind" => "session_new",
                       "args" => %{
                         "workspace" => "esr-dev",
                         "name" => "feature-foo",
                         "tag" => "feature-foo",
                         "cwd" => "/tmp/wt",
                         "worktree" => "feature-foo"
                       }
                     }, {:reply_to, {:pid, ^pid, _ref}}}},
                   500
  end

  test "new-session threads chat_id/thread_id from envelope into args (PR-8 T2)" do
    {:ok, pid} =
      GenServer.start_link(
        SlashHandler,
        %{
          dispatcher: :test_admin_dispatcher,
          session_id: "admin",
          neighbors: [],
          proxy_ctx: %{}
        }
      )

    envelope = %{
      "principal_id" => "p_user",
      "payload" => %{
        "text" =>
          "/new-session esr-dev name=foo cwd=/tmp/wt worktree=foo",
        "chat_id" => "oc_A",
        "thread_id" => "om_B"
      }
    }

    send(pid, {:slash_cmd, envelope, self()})

    assert_receive {:"$gen_cast",
                    {:execute,
                     %{
                       "kind" => "session_new",
                       "args" => %{
                         "workspace" => "esr-dev",
                         "name" => "foo",
                         "chat_id" => "oc_A",
                         "thread_id" => "om_B"
                       }
                     }, {:reply_to, {:pid, ^pid, _ref}}}},
                   500
  end

  test "new-session without chat_id/thread_id in envelope omits them from args" do
    {:ok, pid} =
      GenServer.start_link(
        SlashHandler,
        %{
          dispatcher: :test_admin_dispatcher,
          session_id: "admin",
          neighbors: [],
          proxy_ctx: %{}
        }
      )

    envelope = %{
      "principal_id" => "p_user",
      "payload" => %{
        "text" => "/new-session esr-dev name=foo cwd=/tmp/wt worktree=foo"
      }
    }

    send(pid, {:slash_cmd, envelope, self()})

    assert_receive {:"$gen_cast",
                    {:execute, %{"kind" => "session_new", "args" => args},
                     {:reply_to, {:pid, ^pid, _ref}}}},
                   500

    refute Map.has_key?(args, "chat_id")
    refute Map.has_key?(args, "thread_id")
  end

  test "new-session without name= returns user-facing error" do
    {:ok, pid} =
      GenServer.start_link(
        SlashHandler,
        %{
          dispatcher: :test_admin_dispatcher,
          session_id: "admin",
          neighbors: [],
          proxy_ctx: %{}
        }
      )

    envelope = %{
      "principal_id" => "p_user",
      "payload" => %{"text" => "/new-session esr-dev cwd=/tmp", "chat_id" => "oc_z"}
    }

    send(pid, {:slash_cmd, envelope, self()})

    assert_receive {:reply, text}, 500
    assert text =~ "name="
  end

  test "new-session with legacy --agent/--dir returns hint pointing to new grammar" do
    {:ok, pid} =
      GenServer.start_link(
        SlashHandler,
        %{
          dispatcher: :test_admin_dispatcher,
          session_id: "admin",
          neighbors: [],
          proxy_ctx: %{}
        }
      )

    envelope = %{
      "principal_id" => "p_user",
      "payload" => %{"text" => "/new-session --agent cc --dir /tmp/test", "chat_id" => "oc_z"}
    }

    send(pid, {:slash_cmd, envelope, self()})

    assert_receive {:reply, text}, 500
    assert text =~ "--agent"
    assert text =~ "PR-21d"
    assert text =~ "name="
  end

  test "new-session accepts tag= as alias for name= during rollout" do
    {:ok, pid} =
      GenServer.start_link(
        SlashHandler,
        %{
          dispatcher: :test_admin_dispatcher,
          session_id: "admin",
          neighbors: [],
          proxy_ctx: %{}
        }
      )

    envelope = %{
      "principal_id" => "p_user",
      "payload" => %{"text" => "/new-session esr-dev tag=foo", "chat_id" => "oc_z"}
    }

    send(pid, {:slash_cmd, envelope, self()})

    assert_receive {:"$gen_cast",
                    {:execute,
                     %{
                       "kind" => "session_new",
                       "args" => %{"name" => "foo", "tag" => "foo"}
                     }, {:reply_to, {:pid, ^pid, _ref}}}},
                   500
  end

  test "end-session parses session id argument" do
    {:ok, pid} =
      GenServer.start_link(
        SlashHandler,
        %{
          dispatcher: :test_admin_dispatcher,
          session_id: "admin",
          neighbors: [],
          proxy_ctx: %{}
        }
      )

    envelope = %{
      "principal_id" => "p_user",
      "payload" => %{"text" => "/end-session s-123", "chat_id" => "oc_z"}
    }

    send(pid, {:slash_cmd, envelope, self()})

    assert_receive {:"$gen_cast",
                    {:execute,
                     %{"kind" => "session_end", "args" => %{"session_id" => "s-123"}},
                     {:reply_to, {:pid, ^pid, _ref}}}},
                   500
  end

  test "list-agents parses to agent_list kind" do
    {:ok, pid} =
      GenServer.start_link(
        SlashHandler,
        %{
          dispatcher: :test_admin_dispatcher,
          session_id: "admin",
          neighbors: [],
          proxy_ctx: %{}
        }
      )

    envelope = %{
      "principal_id" => "p_user",
      "payload" => %{"text" => "/list-agents", "chat_id" => "oc_z"}
    }

    send(pid, {:slash_cmd, envelope, self()})

    assert_receive {:"$gen_cast",
                    {:execute, %{"kind" => "agent_list"}, {:reply_to, {:pid, ^pid, _ref}}}},
                   500
  end
end

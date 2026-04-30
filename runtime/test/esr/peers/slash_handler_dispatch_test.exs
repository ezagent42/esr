defmodule Esr.Peers.SlashHandlerDispatchTest do
  @moduledoc """
  Tests for `Esr.Peers.SlashHandler.dispatch/2,3` — the adapter-agnostic
  yaml-driven entry point added in PR-21κ Phase 3.

  These tests run in parallel to the legacy `:slash_cmd` tests in
  `slash_handler_test.exs`. Phase 6 deletes the legacy path; until
  then both APIs are exercised.

  Setup mirrors the legacy file: register `self()` as the fake admin
  dispatcher and assert on the `{:execute, cmd, ...}` cast that the
  SlashHandler emits. Reply-correlation is verified by sending a
  fake `{:command_result, ref, ...}` back and asserting the
  `{:reply, text, ref}` arrives.
  """

  use ExUnit.Case, async: false

  alias Esr.Peers.SlashHandler
  alias Esr.SlashRoutes

  @principal "ou_dispatch_test"

  setup do
    assert is_pid(Process.whereis(Esr.AdminSessionProcess))
    Process.register(self(), :test_admin_dispatcher)

    if Process.whereis(SlashRoutes) == nil, do: start_supervised!(SlashRoutes)
    SlashRoutes.load_snapshot(test_routes())

    on_exit(fn ->
      if Process.whereis(:test_admin_dispatcher),
        do: Process.unregister(:test_admin_dispatcher)
    end)

    :ok
  end

  describe "dispatch/2 — happy path" do
    test "/help dispatches with kind=help, no permission, no args" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/help"), self(), ref)

      assert_receive {:"$gen_cast",
                      {:execute, %{"kind" => "help"} = cmd, {:reply_to, {:pid, ^pid, ^ref}}}},
                     500

      assert cmd["submitted_by"] == @principal
    end

    test "/sessions dispatches with kind=session_list" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/sessions"), self(), ref)

      assert_receive {:"$gen_cast",
                      {:execute, %{"kind" => "session_list"}, {:reply_to, {:pid, ^pid, ^ref}}}},
                     500
    end

    test "/list-sessions alias resolves to same kind" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/list-sessions"), self(), ref)

      assert_receive {:"$gen_cast",
                      {:execute, %{"kind" => "session_list"}, {:reply_to, {:pid, ^pid, ^ref}}}},
                     500
    end

    test "first non-kv token binds to first arg as positional value" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/echo hello kw=world"), self(), ref)

      assert_receive {:"$gen_cast",
                      {:execute, %{"args" => args}, {:reply_to, {:pid, ^pid, ^ref}}}},
                     500

      assert args["positional_one"] == "hello"
      assert args["kw"] == "world"
    end

    test "command_result is relayed back as {:reply, text, ref}" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/sessions"), self(), ref)

      assert_receive {:"$gen_cast", {:execute, _cmd, {:reply_to, {:pid, ^pid, ^ref}}}}, 500

      send(pid, {:command_result, ref, {:ok, %{"branches" => ["main", "dev"]}}})

      assert_receive {:reply, text, ^ref}, 500
      assert is_binary(text)
      assert text =~ "sessions:"
    end
  end

  describe "dispatch/2 — error paths" do
    test "unknown slash → {:reply, \"unknown command\", ref}" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/totally-fake-slash"), self(), ref)

      assert_receive {:reply, text, ^ref}, 500
      assert text =~ "unknown command"
    end

    test "requires_workspace_binding without binding → reply with hint" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/needs-ws name=foo"), self(), ref)

      assert_receive {:reply, text, ^ref}, 500
      assert text =~ "workspace"
      assert text =~ "/new-workspace"
      # Should NOT have cast the command — binding check rejects.
      refute_receive {:"$gen_cast", {:execute, _, _}}, 100
    end

    test "missing required arg → reply with hint pointing at the arg name" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/echo"), self(), ref)

      assert_receive {:reply, text, ^ref}, 500
      assert text =~ "positional_one"
    end
  end

  describe "dispatch/2 — timeout" do
    test "dispatcher silent past timeout → {:reply, \"timed out\", ref}" do
      pid = start_handler!(dispatch_timeout_ms: 60)
      ref = make_ref()
      cast_dispatch(pid, envelope("/sessions"), self(), ref)

      # Cast still fires immediately
      assert_receive {:"$gen_cast", {:execute, _cmd, {:reply_to, {:pid, ^pid, ^ref}}}}, 500

      # We never send command_result back — wait for timeout.
      assert_receive {:reply, text, ^ref}, 500
      assert text =~ "timed out"
    end
  end

  describe "envelope arg injection" do
    test "chat_id, app_id, principal_id are merged into args" do
      pid = start_handler!()

      env =
        envelope("/help")
        |> put_in(["payload", "args", "app_id"], "test_app")
        |> put_in(["payload", "args", "chat_id"], "oc_inject")

      ref = make_ref()
      cast_dispatch(pid, env, self(), ref)

      assert_receive {:"$gen_cast", {:execute, %{"args" => args}, {:reply_to, {:pid, ^pid, ^ref}}}}, 500

      assert args["chat_id"] == "oc_inject"
      assert args["app_id"] == "test_app"
      assert args["principal_id"] == @principal
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp start_handler!(opts \\ []) do
    {:ok, pid} =
      GenServer.start_link(
        SlashHandler,
        Map.merge(
          %{
            dispatcher: :test_admin_dispatcher,
            session_id: "admin",
            neighbors: [],
            proxy_ctx: %{}
          },
          Map.new(opts)
        )
      )

    pid
  end

  # Cast directly to the unnamed test pid (the public dispatch/2 API
  # casts to the named module — fine in production, but in tests the
  # handler is started without :name so we bypass).
  defp cast_dispatch(pid, envelope, reply_to, ref) do
    GenServer.cast(pid, {:dispatch, envelope, reply_to, ref})
  end

  defp envelope(text) do
    %{
      "principal_id" => @principal,
      "payload" => %{
        "text" => text,
        "args" => %{"content" => text}
      }
    }
  end

  # Synthetic test-only routes covering happy + error paths without
  # depending on the priv default (which references real command
  # modules whose execute/1 we don't want to invoke here).
  defp test_routes do
    notify = Esr.Admin.Commands.Notify

    %{
      slashes: [
        %{
          slash: "/help",
          kind: "help",
          permission: nil,
          command_module: notify,
          requires_workspace_binding: false,
          requires_user_binding: false,
          category: "诊断",
          description: "help",
          aliases: [],
          args: []
        },
        %{
          slash: "/sessions",
          kind: "session_list",
          permission: "session.list",
          command_module: notify,
          requires_workspace_binding: false,
          requires_user_binding: false,
          category: "Sessions",
          description: "list",
          aliases: ["/list-sessions"],
          args: []
        },
        %{
          slash: "/echo",
          kind: "echo",
          permission: nil,
          command_module: notify,
          requires_workspace_binding: false,
          requires_user_binding: false,
          category: "Test",
          description: "echo test",
          aliases: [],
          args: [
            %{name: "positional_one", required: true, default: nil},
            %{name: "kw", required: false, default: nil}
          ]
        },
        %{
          slash: "/needs-ws",
          kind: "needs_ws",
          permission: nil,
          command_module: notify,
          requires_workspace_binding: true,
          requires_user_binding: false,
          category: "Test",
          description: "binding test",
          aliases: [],
          args: [%{name: "name", required: true, default: nil}]
        }
      ],
      internal_kinds: []
    }
  end
end

defmodule Esr.Routing.SessionRouterTest do
  @moduledoc """
  DI-9 Task 17 — Router parser + forward-to-Dispatcher.

  `Esr.Routing.SessionRouter` subscribes to the Feishu `msg_received`
  Phoenix.PubSub topic, parses leading-slash admin commands, and casts
  them to `Esr.Admin.Dispatcher` with a `{:reply_to, {:pid, self(), ref}}`
  correlation pattern. Non-command messages are routed to the sender's
  active branch per `routing.yaml`.

  These tests cover:

    * `parse_command/1` — each supported slash syntax + negative path.
    * Slash path — message in → cast out + ref stored + reply on result.
    * Unknown-ref result — gracefully ignored (no crash, no reply).
    * Non-command path — forwarded via `route:<esrd_url>` PubSub topic.
    * `init/1` — loads `routing.yaml` + `branches.yaml` from runtime_home;
      missing files yield empty maps.

  The PubSub name is `EsrWeb.PubSub` (spec says `Esr.PubSub`, but the
  concrete registered name in the runtime is EsrWeb.PubSub — same
  divergence documented in `Esr.Admin.Commands.Notify`).

  The Router is started in isolation (not via Esr.Routing.Supervisor)
  so each test owns the singleton and its subscription list.
  """

  use ExUnit.Case, async: false

  alias Esr.Routing.SessionRouter

  setup do
    # Disposable ESRD_HOME so `Esr.Paths.runtime_home()` points at a
    # dir we control. Seed routing.yaml + branches.yaml as needed per
    # test. Tests that don't seed them exercise the "missing = empty"
    # init path.
    tmp =
      Path.join(
        System.tmp_dir!(),
        "routing_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp, "default"))

    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    # Stop the app-level Routing.Supervisor so its child SessionRouter
    # doesn't race our test's start_link (the Supervisor would restart
    # the Router out from under us on every `stop_session_router/0`
    # call, and repeated restarts would trip the restart intensity and
    # cascade up to Esr.Supervisor — taking Phoenix.PubSub with it).
    stop_routing_supervisor()

    on_exit(fn ->
      stop_session_router()

      # Restart the app-level Routing.Supervisor so subsequent test
      # modules find the Router where they expect it.
      restart_routing_supervisor()

      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, runtime: Path.join(tmp, "default")}
  end

  # ------------------------------------------------------------------
  # parse_command/1 — unit coverage of the pure parser
  # ------------------------------------------------------------------

  describe "parse_command/1" do
    test "/new-session <branch> is session_new with new_worktree=false" do
      assert SessionRouter.parse_command("/new-session feature/foo") ==
               {:slash, "session_new", %{"branch" => "feature/foo", "new_worktree" => false}}
    end

    test "/new-session <branch> --new-worktree sets the flag" do
      assert SessionRouter.parse_command("/new-session feature/foo --new-worktree") ==
               {:slash, "session_new", %{"branch" => "feature/foo", "new_worktree" => true}}
    end

    test "/switch-session <branch> is session_switch" do
      assert SessionRouter.parse_command("/switch-session dev") ==
               {:slash, "session_switch", %{"branch" => "dev"}}
    end

    test "/end-session <branch> is session_end with force=false" do
      assert SessionRouter.parse_command("/end-session feature/bar") ==
               {:slash, "session_end", %{"branch" => "feature/bar", "force" => false}}
    end

    test "/end-session <branch> --force sets the flag" do
      assert SessionRouter.parse_command("/end-session feature/bar --force") ==
               {:slash, "session_end", %{"branch" => "feature/bar", "force" => true}}
    end

    test "/sessions is session_list with empty args" do
      assert SessionRouter.parse_command("/sessions") ==
               {:slash, "session_list", %{}}
    end

    test "/list-sessions is session_list with empty args" do
      assert SessionRouter.parse_command("/list-sessions") ==
               {:slash, "session_list", %{}}
    end

    test "/reload is reload with acknowledge_breaking=false" do
      assert SessionRouter.parse_command("/reload") ==
               {:slash, "reload", %{"acknowledge_breaking" => false}}
    end

    test "/reload --acknowledge-breaking sets the flag" do
      assert SessionRouter.parse_command("/reload --acknowledge-breaking") ==
               {:slash, "reload", %{"acknowledge_breaking" => true}}
    end

    test "non-slash text is :not_command" do
      assert SessionRouter.parse_command("hi there") == :not_command
      assert SessionRouter.parse_command("") == :not_command
      assert SessionRouter.parse_command("  /new-session foo") == :not_command
    end

    test "unknown slash command is :not_command" do
      assert SessionRouter.parse_command("/unknown foo") == :not_command
    end
  end

  # ------------------------------------------------------------------
  # Slash command path: cast + ref stored + reply on result
  # ------------------------------------------------------------------

  describe "slash command path" do
    test "slash command is cast to Dispatcher with {:pid, self, ref} reply-to" do
      {:ok, _pid} = SessionRouter.start_link([])

      # Replace the registered Dispatcher name with this test pid so
      # GenServer.cast(Esr.Admin.Dispatcher, ...) is received here.
      swap_dispatcher_to_self()

      envelope = %{
        "principal_id" => "ou_alice",
        "payload" => %{
          "event_type" => "msg_received",
          "args" => %{"chat_id" => "oc_1", "text" => "/sessions"}
        }
      }

      Phoenix.PubSub.broadcast(EsrWeb.PubSub, "msg_received", {:msg_received, envelope})

      assert_receive {:"$gen_cast",
                      {:execute,
                       %{
                         "kind" => "session_list",
                         "submitted_by" => "ou_alice",
                         "id" => id,
                         "args" => %{}
                       }, {:reply_to, {:pid, _router_pid, ref}}}},
                     1_000

      assert is_binary(id)
      assert is_reference(ref)
    end

    test "command_result with matching ref emits a reply directive broadcast" do
      {:ok, router_pid} = SessionRouter.start_link([])

      swap_dispatcher_to_self()

      # Subscribe to the reply PubSub topic BEFORE triggering the command
      # so the broadcast lands in our inbox.
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "feishu_reply")

      envelope = %{
        "principal_id" => "ou_alice",
        "payload" => %{
          "event_type" => "msg_received",
          "args" => %{"chat_id" => "oc_42", "text" => "/sessions"}
        }
      }

      Phoenix.PubSub.broadcast(EsrWeb.PubSub, "msg_received", {:msg_received, envelope})

      assert_receive {:"$gen_cast", {:execute, _cmd, {:reply_to, {:pid, ^router_pid, ref}}}},
                     1_000

      # Simulate Dispatcher finishing the command.
      send(router_pid, {:command_result, ref, {:ok, %{"branches" => []}}})

      assert_receive {:directive, %{"kind" => "reply", "args" => args}}, 1_000
      assert args["chat_id"] == "oc_42"
      assert is_binary(args["text"])
    end

    test "command_result with unknown ref is ignored gracefully (no crash)" do
      {:ok, router_pid} = SessionRouter.start_link([])

      # A ref never stored in pending_refs must not crash the GenServer.
      send(router_pid, {:command_result, make_ref(), {:ok, %{}}})

      # Give the handler a chance to run. If it crashed, the next call
      # would fail.
      ref = :erlang.monitor(:process, router_pid)
      refute_receive {:DOWN, ^ref, :process, _, _}, 200

      # Process is still alive and responsive.
      assert Process.alive?(router_pid)
    end
  end

  # ------------------------------------------------------------------
  # Non-command path: forward to the active branch's esrd_url
  # ------------------------------------------------------------------

  describe "non-command path" do
    test "routes to active branch's esrd_url via PubSub", %{runtime: runtime} do
      # Seed routing.yaml — ou_alice.active = dev → dev.esrd_url = <url>.
      routing_yaml = """
      principals:
        ou_alice:
          active: dev
          targets:
            dev:
              esrd_url: ws://localhost:4011
            prod:
              esrd_url: ws://localhost:4001
      """

      File.write!(Path.join(runtime, "routing.yaml"), routing_yaml)

      {:ok, _pid} = SessionRouter.start_link([])

      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "route:ws://localhost:4011")

      envelope = %{
        "principal_id" => "ou_alice",
        "payload" => %{
          "event_type" => "msg_received",
          "args" => %{"chat_id" => "oc_1", "text" => "hello world"}
        }
      }

      Phoenix.PubSub.broadcast(EsrWeb.PubSub, "msg_received", {:msg_received, envelope})

      assert_receive {:forward, ^envelope}, 1_000
    end

    test "sender with no routing entry is silently dropped" do
      # No routing.yaml — the init-time load yields an empty map, so
      # no broadcast happens for any sender.
      {:ok, router_pid} = SessionRouter.start_link([])

      envelope = %{
        "principal_id" => "ou_unknown",
        "payload" => %{
          "event_type" => "msg_received",
          "args" => %{"chat_id" => "oc_x", "text" => "hi"}
        }
      }

      Phoenix.PubSub.broadcast(EsrWeb.PubSub, "msg_received", {:msg_received, envelope})

      # Let the message be processed; then confirm the router is still
      # alive (didn't crash on the missing route).
      Process.sleep(50)
      assert Process.alive?(router_pid)
    end
  end

  # ------------------------------------------------------------------
  # init/1 — yaml loading
  # ------------------------------------------------------------------

  describe "init/1 yaml loading" do
    test "loads routing.yaml + branches.yaml from Esr.Paths.runtime_home()",
         %{runtime: runtime} do
      File.write!(Path.join(runtime, "routing.yaml"), """
      principals:
        ou_a:
          active: dev
      """)

      File.write!(Path.join(runtime, "branches.yaml"), """
      branches:
        dev:
          port: 4011
      """)

      {:ok, pid} = SessionRouter.start_link([])

      state = :sys.get_state(pid)
      assert state.routing["principals"]["ou_a"]["active"] == "dev"
      assert state.branches["branches"]["dev"]["port"] == 4011
    end

    test "missing routing.yaml + branches.yaml yields empty maps" do
      {:ok, pid} = SessionRouter.start_link([])

      state = :sys.get_state(pid)
      assert state.routing == %{}
      assert state.branches == %{}
      assert state.pending_refs == %{}
    end
  end

  # ------------------------------------------------------------------
  # helpers
  # ------------------------------------------------------------------

  defp stop_session_router do
    case Process.whereis(SessionRouter) do
      nil ->
        :ok

      pid ->
        # Terminate with :normal so ExUnit doesn't log a crash; wait
        # briefly for the name to be unregistered.
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          500 -> :ok
        end
    end
  end

  # Terminate the app-level Routing.Supervisor so its :one_for_one
  # child restart doesn't race our test-owned start_link. Best-effort
  # — this is called from setup, where the Supervisor may or may not
  # be alive depending on test ordering.
  defp stop_routing_supervisor do
    if Process.whereis(Esr.Supervisor) do
      _ = Supervisor.terminate_child(Esr.Supervisor, Esr.Routing.Supervisor)
    end

    :ok
  end

  defp restart_routing_supervisor do
    if Process.whereis(Esr.Supervisor) do
      _ = Supervisor.restart_child(Esr.Supervisor, Esr.Routing.Supervisor)
    end

    :ok
  end

  # For cast-capture tests: the real `Esr.Admin.Dispatcher` GenServer is
  # likely running app-wide. Re-registering the name to the test pid
  # lets us observe the exact `{:"$gen_cast", ...}` message the Router
  # sends, without needing a mock module. We re-register on exit.
  defp swap_dispatcher_to_self do
    test_pid = self()

    original = Process.whereis(Esr.Admin.Dispatcher)

    if original && original != test_pid do
      Process.unregister(Esr.Admin.Dispatcher)
    end

    # Only register if no existing registration conflicts.
    case Process.whereis(Esr.Admin.Dispatcher) do
      nil -> Process.register(test_pid, Esr.Admin.Dispatcher)
      _ -> :ok
    end

    on_exit(fn ->
      case Process.whereis(Esr.Admin.Dispatcher) do
        ^test_pid -> Process.unregister(Esr.Admin.Dispatcher)
        _ -> :ok
      end

      if original && Process.alive?(original) do
        try do
          Process.register(original, Esr.Admin.Dispatcher)
        rescue
          ArgumentError -> :ok
        end
      end
    end)
  end
end

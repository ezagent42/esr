defmodule Esr.Entity.SlashHandlerDispatchTest do
  @moduledoc """
  Tests for `Esr.Entity.SlashHandler.dispatch/2,3` — the adapter-agnostic
  yaml-driven entry point.

  Post PR-2.3b-2: SlashHandler runs commands locally (Esr.Admin.Dispatcher
  was deleted). These tests assert the end-to-end behaviour through
  `{:reply, text, ref}` arriving at the configured reply target,
  rather than the internal cast wire format that no longer exists.

  A `TestEcho` command module is registered as the command_module for
  test routes; it returns a deterministic `{:ok, %{"text" =>
  "echo:<kind>"}}` so test assertions can pin the reply.
  """

  use ExUnit.Case, async: false

  alias Esr.Entity.SlashHandler
  alias Esr.Resource.SlashRoute.Registry, as: SlashRouteRegistry

  @principal "ou_dispatch_test"

  defmodule TestEcho do
    @moduledoc "Fake command module — returns the kind in result text."
    def execute(%{"kind" => kind, "args" => args}) do
      {:ok, %{"text" => "echo:#{kind}", "args" => args}}
    end

    def execute(%{"kind" => kind}) do
      {:ok, %{"text" => "echo:#{kind}"}}
    end
  end

  defmodule TestSilent do
    @moduledoc "Fake command module that hangs — used for timeout tests."
    def execute(_), do: Process.sleep(:infinity)
  end

  setup do
    assert is_pid(Process.whereis(Esr.Session.Admin.Process))

    if Process.whereis(SlashRouteRegistry) == nil, do: start_supervised!(SlashRouteRegistry)
    SlashRouteRegistry.load_snapshot(test_routes())

    on_exit(fn ->
      # Restore the priv default so cross-file tests (Notify, etc.)
      # keep working — they look up kind → permission via
      # SlashRouteRegistry ETS.
      priv = Application.app_dir(:esr, "priv/slash-routes.default.yaml")
      if File.exists?(priv), do: Esr.Resource.SlashRoute.Registry.FileLoader.load(priv)
    end)

    :ok
  end

  describe "dispatch — chat-text path" do
    test "/help executes command and reply text reaches reply target" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/help"), self(), ref)

      assert_receive {:reply, text, ^ref}, 1000
      assert text =~ "echo:help"
    end

    test "/session:list executes its kind=session_list" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/session:list"), self(), ref)

      assert_receive {:reply, text, ^ref}, 1000
      assert text =~ "echo:session_list"
    end

    test "old /sessions returns deprecated hint mentioning /session:list" do
      # Phase 6: /sessions is removed; dispatcher returns a rename hint.
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/sessions"), self(), ref)

      assert_receive {:reply, text, ^ref}, 1000
      assert text =~ "/session:list"
    end

    # Phase C (resource-typed grammar rev-3 §4.2): the per-agent commands
    # were renamed from /session:* to /agent:* (Tasks C.3-C.5). Operators
    # who still type the old form get a rename hint via @deprecated_slashes.
    test "/session:add-agent returns rename hint to /agent:add" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/session:add-agent type=cc name=x"), self(), ref)

      assert_receive {:reply, text, ^ref}, 1000
      assert text =~ "/agent:add"
      assert text =~ "renamed"
    end

    test "/session:remove-agent returns rename hint to /agent:remove" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/session:remove-agent name=x"), self(), ref)

      assert_receive {:reply, text, ^ref}, 1000
      assert text =~ "/agent:remove"
      assert text =~ "renamed"
    end

    test "/session:set-primary returns rename hint to /agent:set-primary" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/session:set-primary name=x"), self(), ref)

      assert_receive {:reply, text, ^ref}, 1000
      assert text =~ "/agent:set-primary"
      assert text =~ "renamed"
    end

    # Phase D (resource-typed grammar rev-3 §4.2 + §4.3): chat-binding
    # split from PTY URL emission. /session:attach is now /session:bind-chat;
    # /session:detach is /session:unbind-chat. Operators typing the old
    # forms get a rename hint via @deprecated_slashes.
    test "/session:attach returns rename hint to /session:bind-chat" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/session:attach session=abc"), self(), ref)

      assert_receive {:reply, text, ^ref}, 1000
      assert text =~ "/session:bind-chat"
      assert text =~ "renamed"
    end

    test "/session:detach returns rename hint to /session:unbind-chat" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/session:detach"), self(), ref)

      assert_receive {:reply, text, ^ref}, 1000
      assert text =~ "/session:unbind-chat"
      assert text =~ "renamed"
    end

    test "/attach now hints to /pty:attach (was /session:attach)" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/attach"), self(), ref)

      assert_receive {:reply, text, ^ref}, 1000
      assert text =~ "/pty:attach"
      assert text =~ "renamed"
    end

    test "envelope chat_id/app_id/principal_id flow into the command's args" do
      pid = start_handler!()
      ref = make_ref()

      env =
        envelope("/echo positional_one=hello")
        |> put_in(["payload", "args", "app_id"], "test_app")
        |> put_in(["payload", "args", "chat_id"], "oc_inject")

      cast_dispatch(pid, env, self(), ref)

      assert_receive {:reply, text, ^ref}, 1000
      # TestEcho echoes the args back via inspect; "ok: %{...}" format
      # from ChatPid.format_result for non-text result maps.
      assert text =~ "echo:echo"
    end
  end

  describe "Phase B — chat-bound /session:list + /session:switch" do
    # Override the test_routes/0 snapshot so /session:list + /session:switch
    # dispatch to the REAL command modules. Validates the slash → module
    # wiring at the dispatch layer (regression for the C-1 review finding:
    # `Session.Switch.execute/1` had no chat-bound clause; ETS-level lookup
    # tests passed but operator-typed `/session:switch session=<uuid>` failed).
    setup do
      case Process.whereis(Esr.Session.ChatRouting.Registry) do
        nil -> start_supervised!(Esr.Session.ChatRouting.Registry)
        _ -> :ok
      end

      SlashRouteRegistry.load_snapshot(%{
        slashes: [
          %{
            slash: "/session:list",
            kind: "session_list",
            permission: nil,
            command_module: Esr.Commands.Session.List,
            requires_workspace_binding: false,
            requires_user_binding: false,
            category: "Sessions",
            description: "list sessions",
            aliases: [],
            args: [%{name: "workspace", required: false, default: nil}]
          },
          %{
            slash: "/session:switch",
            kind: "session_switch",
            permission: nil,
            command_module: Esr.Commands.Session.Switch,
            requires_workspace_binding: false,
            requires_user_binding: false,
            category: "Sessions",
            description: "switch chat current session",
            aliases: [],
            args: [%{name: "session", required: true, default: nil}]
          }
        ],
        internal_kinds: []
      })

      :ok
    end

    test "/session:list with chat context returns chat-bound shape" do
      chat = "oc_phb_disp"
      app = "esr_helper_disp"
      sid = "11111111-aaaa-4aaa-8aaa-111111111111"
      :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid)

      pid = start_handler!()
      ref = make_ref()

      env =
        envelope("/session:list")
        |> put_in(["payload", "args", "chat_id"], chat)
        |> put_in(["payload", "args", "app_id"], app)

      cast_dispatch(pid, env, self(), ref)

      # Session.List chat-bound shape returns
      # %{"sessions" => [...], "chat_id" => ...}; ChatPid.format_result
      # falls through to "ok: " <> inspect(m) for non-workspace shapes.
      assert_receive {:reply, text, ^ref}, 1000
      assert text =~ "sessions"
      assert text =~ sid
    end

    test "/session:switch with session=<uuid> + chat context promotes the session" do
      chat = "oc_phb_sw"
      app = "esr_helper_sw"
      sid_a = "22222222-bbbb-4bbb-8bbb-222222222222"
      sid_b = "33333333-cccc-4ccc-8ccc-333333333333"

      :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid_a)
      :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid_b)

      # First attach made sid_a current; second attach kept current=sid_a
      # (attach_session/3 only overwrites current when current was nil).
      assert {:ok, ^sid_a} = Esr.Session.ChatRouting.Registry.current_session(chat, app)

      pid = start_handler!()
      ref = make_ref()

      env =
        envelope("/session:switch session=" <> sid_b)
        |> put_in(["payload", "args", "chat_id"], chat)
        |> put_in(["payload", "args", "app_id"], app)

      cast_dispatch(pid, env, self(), ref)

      assert_receive {:reply, text, ^ref}, 1000
      # Result is %{"session_id" => sid_b, "switched" => true, ...};
      # ChatPid.format_result hits the {"session_id", "switched" => true}
      # clause and renders "switched chat-current session → <sid>".
      # (Spec rev-4 §4.2 second-review fix #2 — the generic
      # {"session_id"} clause was previously shadowing this and rendering
      # "session started", misleading operators into believing a new
      # session had been created.)
      assert text =~ sid_b
      assert text =~ "switched"
      refute text =~ "started"

      # Verify the registry promotion actually landed.
      assert {:ok, ^sid_b} = Esr.Session.ChatRouting.Registry.current_session(chat, app)
    end
  end

  describe "dispatch — error paths" do
    test "unknown slash → reply with 'unknown command' text" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/totally-fake-slash"), self(), ref)

      assert_receive {:reply, text, ^ref}, 1000
      assert text =~ "unknown command"
    end

    test "requires_workspace_binding without binding → reply with hint" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/needs-ws name=foo"), self(), ref)

      assert_receive {:reply, text, ^ref}, 1000
      assert text =~ "workspace"
      assert text =~ "/workspace:new"
    end

    test "missing required arg → reply with hint" do
      pid = start_handler!()
      ref = make_ref()
      cast_dispatch(pid, envelope("/echo"), self(), ref)

      assert_receive {:reply, text, ^ref}, 1000
      assert text =~ "positional_one"
    end
  end

  describe "dispatch — timeout" do
    test "stuck command past timeout → reply 'command timed out'" do
      pid = start_handler!(dispatch_timeout_ms: 60)
      ref = make_ref()
      cast_dispatch(pid, envelope("/silent"), self(), ref)

      assert_receive {:reply, text, ^ref}, 1000
      assert text =~ "timed out"
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
            session_id: "admin",
            neighbors: [],
            proxy_ctx: %{}
          },
          Map.new(opts)
        )
      )

    pid
  end

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

  defp test_routes do
    %{
      slashes: [
        route("/help", "help"),
        route("/session:list", "session_list"),
        route("/echo", "echo",
          args: [
            %{name: "positional_one", required: true, default: nil},
            %{name: "kw", required: false, default: nil}
          ]
        ),
        route("/needs-ws", "needs_ws",
          requires_workspace_binding: true,
          args: [%{name: "name", required: true, default: nil}]
        ),
        route("/silent", "silent", command_module: TestSilent)
      ],
      internal_kinds: []
    }
  end

  defp route(slash, kind, opts \\ []) do
    %{
      slash: slash,
      kind: kind,
      permission: nil,
      command_module: Keyword.get(opts, :command_module, TestEcho),
      requires_workspace_binding: Keyword.get(opts, :requires_workspace_binding, false),
      requires_user_binding: false,
      category: "test",
      description: "test",
      aliases: Keyword.get(opts, :aliases, []),
      args: Keyword.get(opts, :args, [])
    }
  end
end

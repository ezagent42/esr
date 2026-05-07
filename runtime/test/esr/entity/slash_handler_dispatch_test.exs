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
    assert is_pid(Process.whereis(Esr.Scope.Admin.Process))

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

defmodule Esr.Integration.FeishuSlashNewSessionTest do
  @moduledoc """
  PR-8 T3 — Full Feishu `/new-session` flow, end-to-end.

  Simulates:

    1. User DMs bot: envelope with `content_text`
       `"/new-session esr-dev name=t3"`, `chat_id "oc_slashsession"`,
       `thread_id "om_slashsession"`.
    2. FeishuChatProxy detects the slash (via a direct send to the
       SlashHandler, mirroring `FeishuChatProxy.handle_upstream/2`'s
       `send(slash_pid, {:slash_cmd, envelope, self()})`).
    3. SlashHandler parses, emits `session_new` with `chat_id`/`thread_id`.
    4. `Session.New` creates the session **and** registers it in
       `SessionRegistry` — this is the T3 loop-closing behaviour.
    5. A second inbound envelope for the same `chat_id`/`thread_id` now
       resolves to the newly-created session via
       `SessionRegistry.lookup_by_chat_thread/3` — proving the binding loop.

  The integration test uses the production SlashHandler started by
  `Esr.Session.Admin.bootstrap_slash_handler/0` (PR-8 T1). No stubs — the
  full command path runs through `Esr.Admin.Dispatcher` → `Session.New`.

  ## PR-8 T4 update

  Post-T4, `Session.New` delegates the chat-bound branch to
  `Esr.Session.Router.create_session/1`, which spawns the full
  `pipeline.inbound` (FeishuChatProxy, CCProxy, CCProcess, PtyProcess)
  and registers the session with refs carrying each spawned peer pid.
  This test still asserts the T3 invariant (`lookup_by_chat_thread/3`
  returns the newly-created session); the T4-specific assertion —
  that `refs.feishu_chat_proxy` is a live pid — lives in
  `Esr.Commands.Session.NewTest`'s `:t4_session_router` describe
  block rather than here, to keep each test focused.
  """
  use ExUnit.Case, async: false

  # PR-21κ Phase 6: tagged :integration — dispatch/3 enforces workspace +
  # user binding; setup writes to global Workspaces / Users registries.
  @moduletag :integration

  import Esr.TestSupport.AppSingletons, only: [assert_with_grants: 1]
  import Esr.TestSupport.SessionsCleanup, only: [wipe_sessions_on_exit: 1]

  alias Esr.Entity.SlashHandler

  @test_principal "ou_t3_flow"
  @chat_id "oc_slashsession"
  @thread_id "om_slashsession"

  setup :assert_with_grants
  setup :wipe_sessions_on_exit

  setup do
    ensure_admin_dispatcher()
    assert is_pid(Process.whereis(Esr.Admin.Dispatcher))

    # Phase 6 (2026-05-10): legacy `Esr.Entity.Agent.Registry` cache
    # gone; Session.New resolves an agent_def via SessionTemplate +
    # plugin manifest agent_kinds. Register the kinds + a feishu-cc
    # template so dispatch finds them.
    case Process.whereis(Esr.SessionTemplate.Registry) do
      nil -> start_supervised!(Esr.SessionTemplate.Registry)
      _ -> :ok
    end

    case Process.whereis(Esr.Channel.Registry) do
      nil -> start_supervised!(Esr.Channel.Registry)
      _ -> :ok
    end

    case Process.whereis(Esr.Plugin.AgentKindRegistry) do
      nil -> start_supervised!(Esr.Plugin.AgentKindRegistry)
      _ -> :ok
    end

    Esr.Channel.Registry.register("feishu", "chat_proxy", Esr.Plugins.Feishu.Channels.ChatProxy, %{
      pipeline_contributions: [
        %{"name" => "feishu_chat_proxy", "impl" => "Esr.Plugins.Feishu.FeishuChatProxy"}
      ],
      proxies: [
        %{
          "name" => "feishu_app_proxy",
          "impl" => "Esr.Entity.FeishuAppProxy",
          "target" => "admin::feishu_app_adapter_${app_id}"
        }
      ]
    })

    Esr.Channel.Registry.register(
      "claude_code",
      "mcp_http",
      Esr.Plugins.ClaudeCode.Channels.McpHttp,
      %{pipeline_contributions: [], proxies: []}
    )

    Esr.Plugin.AgentKindRegistry.register("claude_code", "cc", %{
      plugin: "claude_code",
      name: "cc",
      description: "Claude Code",
      handler_module: "cc_adapter_runner",
      pipeline: %{
        inbound: [
          %{"name" => "cc_proxy", "impl" => "Esr.Entity.CCProxy"},
          %{"name" => "cc_process", "impl" => "Esr.Entity.CCProcess"},
          %{"name" => "pty_process", "impl" => "Esr.Entity.PtyProcess"}
        ],
        outbound: ["pty_process", "cc_process", "cc_proxy"]
      },
      proxies: [],
      capabilities_required: [
        "session:default/create",
        "pty:default/spawn",
        "handler:cc_adapter_runner/invoke"
      ],
      params: []
    })

    Esr.SessionTemplate.Registry.register(
      "feishu-cc",
      %Esr.SessionTemplate{
        schema_version: 1,
        name: "feishu-cc",
        description: "Feishu chat → Claude Code agent",
        dependencies: %{plugins: ["feishu", "claude_code"], bundles: []},
        channels: [
          %{alias: "in", kind: "feishu.chat_proxy", config: %{}},
          %{alias: "cc_mcp", kind: "claude_code.mcp_http", config: %{}}
        ],
        agents: [%{kind: "claude_code.cc", name: "<runtime>", consumes: ["cc_mcp"]}],
        flow: %{inbound: [], outbound: []}
      },
      source: {:bundle, "feishu-cc"}
    )

    session_dir = Path.join(System.tmp_dir!(), "esr_feishu_slash_smoke_#{:rand.uniform(99_999)}")
    File.mkdir_p!(session_dir)
    :ok = Esr.Session.DefaultTemplate.set("feishu-cc", global_path: session_dir)

    prod_dir = Esr.Paths.plugin_global_dir("session")
    File.mkdir_p!(prod_dir)
    File.write!(Path.join(prod_dir, "config.yaml"), ~s(default_template: "feishu-cc"\n))

    if Process.whereis(Esr.Session.Router) == nil do
      start_supervised!(Esr.Session.Router)
    end

    :ok = Esr.TestSupport.Grants.with_grants(%{@test_principal => ["*"]})

    # PR-8 T1: SlashHandler is auto-started by
    # `Esr.Session.Admin.bootstrap_slash_handler/0` at application boot,
    # so we only need to re-spawn if a sibling torched it.
    slash_pid =
      case Esr.Session.Admin.Process.slash_handler_ref() do
        {:ok, pid} ->
          pid

        :error ->
          {:ok, pid} =
            start_supervised(%{
              id: :t3_slash_handler,
              start:
                {SlashHandler, :start_link,
                 [%{session_id: "admin", neighbors: [], proxy_ctx: %{}}]}
            })

          pid
      end

    on_exit(fn ->
      # PR-A T1: Scope.Router defaults app_id to "default" when the
      # slash flow doesn't carry one (T3 will surface app_id explicitly).
      Esr.Session.ChatRouting.Registry.current_session(@chat_id, "default")
      |> case do
        {:ok, sid} -> Esr.Session.ChatRouting.Registry.detach_session_by_id(sid)
        _ -> :ok
      end
    end)

    # PR-21θ 2026-04-30: tmp git repo so `root= worktree=` succeeds.
    smoke_repo = Path.join(System.tmp_dir!(), "feishu_slash_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(smoke_repo)
    {_, 0} = System.cmd("git", ["-C", smoke_repo, "init", "-q", "-b", "main"])
    {_, 0} = System.cmd("git", ["-C", smoke_repo, "commit", "--allow-empty", "-q", "-m", "init"])
    {_, 0} = System.cmd("git", ["-C", smoke_repo, "remote", "add", "origin", smoke_repo])
    {_, 0} = System.cmd("git", ["-C", smoke_repo, "fetch", "origin", "-q"])

    on_exit(fn -> File.rm_rf!(smoke_repo) end)

    # PR-21κ Phase 6: dispatch/3 enforces requires_workspace_binding +
    # requires_user_binding for /new-session per slash-routes.yaml.
    # Set up an in-memory workspace + user for the test chat so the
    # preconditions pass. These pre-existed at the legacy `:slash_cmd`
    # path's level (it had no gates), so this setup is new for the
    # production-equivalent dispatch path.
    test_app_id = "default"

    workspace =
      Esr.Test.WorkspaceFixture.build(
        name: "esr-dev",
        owner: "t3_user",
        role: "dev",
        chats: [%{"chat_id" => @chat_id, "app_id" => test_app_id}]
      )

    Esr.Resource.Workspace.Registry.put(workspace)

    Esr.Entity.User.Registry.load_snapshot(%{
      "t3_user" => %Esr.Entity.User.Struct{
        username: "t3_user",
        feishu_ids: [@test_principal]
      }
    })

    {:ok, slash: slash_pid, smoke_repo: smoke_repo, app_id: test_app_id}
  end

  # Phase 6 colon-namespace cutover: /new-session is now a dead form.
  # The full E2E session-creation test will be re-implemented when
  # Esr.Commands.Session.New ships (follow-up phase).
  # For now, verify the old form returns a deprecated-slash hint.
  test "old /new-session returns deprecated-slash hint pointing to /session:new",
       %{smoke_repo: smoke_repo, app_id: app_id} do
    branch = "t3-#{System.unique_integer([:positive])}"

    envelope = %{
      "principal_id" => @test_principal,
      "payload" => %{
        "text" => "/new-session esr-dev name=t3 root=#{smoke_repo} worktree=#{branch}",
        "args" => %{"app_id" => app_id, "chat_id" => @chat_id},
        "chat_id" => @chat_id,
        "thread_id" => @thread_id
      }
    }

    ref = Esr.Entity.SlashHandler.dispatch(envelope, self(), make_ref())

    assert_receive {:reply, text, ^ref}, 2_000
    assert text =~ "/session:new",
           "expected deprecated-slash hint mentioning /session:new, got: #{inspect(text)}"
  end

  # Borrowed from Esr.Integration.NewSessionSmokeTest — tests that restart
  # the Admin.Supervisor may race against siblings.
  defp ensure_admin_dispatcher do
    if Process.whereis(Esr.Admin.Dispatcher) == nil do
      _ = Supervisor.restart_child(Esr.Supervisor, Esr.Slash.Supervisor)

      if Process.whereis(Esr.Admin.Dispatcher) == nil do
        {:ok, _} = Esr.Slash.Supervisor.start_link([])
      end
    end

    :ok
  end
end

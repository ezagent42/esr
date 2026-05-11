defmodule Esr.Integration.RealClaudeBootTest do
  @moduledoc """
  PR-4 (2026-05-11 default-agent + agent-driven-flow plan §5.4):
  end-to-end boot test against the real `claude` binary.

  Exercised on developer machines + macos-latest CI. Skipped on any
  runner where `claude` is not on PATH — the `:real_claude` moduletag
  is excluded from the default test run (see `runtime/test/test_helper.exs`
  and the dev workflow). The CI `real-claude-integration` job opts in
  via `--only real_claude`.

  ## What this verifies

    1. `Esr.Paths.session_mcp_json/1` exists on disk after session
       create (Launcher.write_mcp_json ran)
    2. The session's `:feishu_chat_proxy` role pid is registered in
       Entity.Registry (FCP supervised + alive)
    3. The session's `:cc_process` role pid is registered (CCProcess
       supervised + alive)
    4. The `cc_mcp_ready/<sid>` PubSub topic on `EsrWeb.PubSub` fires —
       confirming claude's MCP client successfully connected to the
       ESRD HTTP MCP endpoint and the controller broadcast readiness.

  The follow-up chat-reply round-trip step from the plan sketch is
  intentionally NOT asserted: it requires a real Feishu app credential
  and a registered FAA, which a fresh CI runner won't have. If the test
  runs to step 4 successfully, the boot pipeline is sound; chat reply
  is a separate concern verified by manual e2e + the existing
  `cc_e2e_test.exs` stubbed-handler flow.
  """

  use ExUnit.Case, async: false
  @moduletag :real_claude

  alias Esr.Paths

  @setup_timeout_ms 30_000

  setup do
    case System.find_executable("claude") do
      nil ->
        # ExUnit doesn't have a true "skip"; emit a tag-equivalent and
        # short-circuit the test body via a setup-context flag.
        {:ok, skip: true, reason: "claude binary not on PATH"}

      path ->
        {:ok, skip: false, claude_binary: path}
    end
  end

  @tag timeout: 120_000
  test "real claude boots: mcp.json written + FCP + CCProcess + cc_mcp_ready broadcast",
       %{skip: skip} = ctx do
    if skip do
      IO.puts("\n[real_claude] SKIPPED: #{ctx[:reason]}")
      :ok
    else
      run_boot_assertions(ctx)
    end
  end

  defp run_boot_assertions(_ctx) do
    sid = create_real_claude_session()

    # Subscribe BEFORE polling so we can race-safely catch the broadcast.
    if Process.whereis(EsrWeb.PubSub) do
      Phoenix.PubSub.subscribe(EsrWeb.PubSub, "cc_mcp_ready/" <> sid)
    end

    assert eventually(fn -> File.exists?(Paths.session_mcp_json(sid)) end, @setup_timeout_ms),
           "session_mcp_json must exist at #{Paths.session_mcp_json(sid)}"

    assert eventually(fn -> role_pid_alive?(sid, :feishu_chat_proxy) end, @setup_timeout_ms),
           "feishu_chat_proxy must be registered + alive for sid=#{sid}"

    assert eventually(fn -> role_pid_alive?(sid, :cc_process) end, @setup_timeout_ms),
           "cc_process must be registered + alive for sid=#{sid}"

    # cc_mcp_ready broadcast: either already received (from PubSub subscribe
    # above) or we observe it in the next 60s while claude finishes booting
    # and dialing the MCP endpoint.
    assert_receive {:cc_mcp_ready, ^sid}, 60_000

    cleanup_session(sid)
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp create_real_claude_session do
    chat_id = "oc_real_#{System.unique_integer([:positive])}"
    thread_id = "om_real_#{System.unique_integer([:positive])}"
    app_id = "real_#{System.unique_integer([:positive])}"

    # Spawn a FAA so chat-routing has somewhere to land outbound (the
    # boot path subscribes pty:<sid> on FCP but doesn't actually emit
    # a chat reply in this assertion window).
    admin_children_sup = Esr.Session.Admin.ChildrenSupervisor

    {:ok, faa} =
      DynamicSupervisor.start_child(
        admin_children_sup,
        {Esr.Entity.FeishuAppAdapter,
         %{app_id: app_id, neighbors: [], proxy_ctx: %{}}}
      )

    on_exit(fn ->
      if Process.alive?(faa) do
        DynamicSupervisor.terminate_child(admin_children_sup, faa)
      end
    end)

    # Workspace dir: a fresh empty tmp folder so claude has a sane cwd
    # (and PtyProcess can mkdir_p without colliding).
    workspace_dir =
      Path.join(System.tmp_dir!(), "real_claude_ws_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_dir)

    on_exit(fn -> File.rm_rf(workspace_dir) end)

    {:ok, cc_def} = real_claude_agent_def()

    {:ok, sid} =
      Esr.Session.Router.create_session(%{
        agent: "cc",
        dir: workspace_dir,
        principal_id: "ou_real_claude_test",
        chat_id: chat_id,
        thread_id: thread_id,
        app_id: app_id,
        agent_def: cc_def
      })

    sid
  end

  # Minimal cc agent_def shape for create_session. Mirrors what the
  # AgentDefFixture builds from agents/simple.yaml but inline since this
  # test deliberately avoids the stubbed-handler override (we want the
  # REAL claude binary path).
  defp real_claude_agent_def do
    {:ok,
     %{
       "type" => "cc",
       "name" => "real-claude-boot",
       "config" => %{}
     }}
  end

  defp role_pid_alive?(sid, role) do
    case Esr.ActorQuery.list_by_role(sid, role) do
      [pid | _] when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  # Poll a 0-arity bool fn until it returns true or the deadline expires.
  # Returns false on timeout so callers can `assert` cleanly.
  defp eventually(fun, timeout_ms) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(100)
        do_eventually(fun, deadline)
      end
    end
  end

  defp cleanup_session(sid) do
    try do
      Esr.Session.Router.end_session(sid)
    catch
      _, _ -> :ok
    end
  end
end

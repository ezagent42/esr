defmodule Esr.Integration.NewSessionSmokeTest do
  @moduledoc """
  P2-13: E2E smoke test for `/new-session --agent cc --dir /tmp/test`.

  Exercises the full PR-2 slash-command path end-to-end:

      FeishuChatProxy-style envelope
              |
              v
      Esr.Peers.SlashHandler  — parses the slash, casts session_new
              |
              v
      Esr.Admin.Dispatcher    — cap-checks (D18) + Tasks the command
              |
              v
      Esr.Admin.Commands.Session.New       — validates args (D11/D13),
              |                              re-checks agent_def caps,
              |                              calls SessionsSupervisor
              v
      Esr.SessionsSupervisor  — starts Esr.Session (SessionProcess +
                                 empty peers DynamicSupervisor)
              |
              v
      Reply relayed back to the originating "ChatProxy" (this test's
      pid) as `{:reply, "session started: <sid>"}`.

  Controlled failure mode (spec §P2-13): PR-2 does NOT yet spawn the
  pipeline peers (CCProcess, TmuxProcess are PR-3 work). Session.init
  only brings up SessionProcess + an empty peers DynamicSupervisor,
  so the happy-path command succeeds and the peers sup is asserted
  childless. Future PR-3 work populates the pipeline from agent_def.

  Intentionally NOT tagged `:integration` per P2-13 task note: the
  whole path is pure Elixir + supervisor tree, no OS processes, so
  it runs in the default `mix test` profile.

  ## Drift from expansion doc

  P3-8 cleaned up the earlier drift: the SlashHandler's
  missing-capabilities format_result/1 clause now matches on the string
  `"missing_capabilities"` (matching `Session.New`'s actual emission),
  and the dispatcher's `session_new` permission is now
  `session:default/create` (canonical form). The text assertion below
  still accepts either `unauthorized` (dispatcher-level) or
  `missing_capabilities` (command-level) because the `ou_smoke_nocap`
  principal lacks every grant — the dispatcher rejects first.
  """
  use ExUnit.Case, async: false

  alias Esr.Capabilities.Grants
  alias Esr.Peers.SlashHandler

  @test_principal "ou_smoke_user"
  @test_principal_nocap "ou_smoke_nocap"

  setup do
    # App-level singletons (booted by Esr.Application):
    assert is_pid(Process.whereis(Esr.SessionRegistry))
    assert is_pid(Process.whereis(Esr.AdminSessionProcess))
    assert is_pid(Process.whereis(Esr.SessionsSupervisor))
    assert is_pid(Process.whereis(Esr.Session.Registry))
    assert is_pid(Process.whereis(Grants))

    # `Esr.Admin.Dispatcher` may have been torn down by a prior
    # dispatcher_test.exs that restarts the Admin.Supervisor — mirror
    # its `ensure_admin_dispatcher` shim so we're robust to ordering.
    ensure_admin_dispatcher()
    assert is_pid(Process.whereis(Esr.Admin.Dispatcher))

    :ok =
      Esr.SessionRegistry.load_agents(
        Path.expand("../fixtures/agents/simple.yaml", __DIR__)
      )

    # Snapshot grants so we can restore on exit. The test principal gets
    # `"*"` (only grant shape that passes the current bare-string-keyed
    # matcher in `Esr.Capabilities.Grants.matches?/2` for both the
    # Dispatcher check and the agent_def D18 check). A second principal
    # gets nothing so we can exercise the unauthorized branch.
    prior_grants = snapshot_grants()

    :ok =
      Grants.load_snapshot(
        prior_grants
        |> Map.put(@test_principal, ["*"])
        |> Map.put(@test_principal_nocap, [])
      )

    # Esr.Peers.SlashHandler is NOT auto-started by Esr.Application —
    # SessionRouter spawns it per-Session. Start it explicitly under
    # test_supervisor so it registers under :slash_handler in
    # AdminSessionProcess. (The legacy Routing.SlashHandler was
    # deleted in PR-3 P3-14.)
    {:ok, slash_pid} =
      start_supervised(%{
        id: :smoke_slash_handler,
        start:
          {SlashHandler, :start_link,
           [%{session_id: "admin", neighbors: [], proxy_ctx: %{}}]}
      })

    on_exit(fn ->
      Grants.load_snapshot(prior_grants)

      # Wipe any dynamically-started Sessions so tests don't pollute
      # each other via the shared app-level DynamicSupervisor.
      case Process.whereis(Esr.SessionsSupervisor) do
        nil ->
          :ok

        pid ->
          for {_, child, _, _} <- DynamicSupervisor.which_children(pid) do
            if is_pid(child),
              do: DynamicSupervisor.terminate_child(pid, child)
          end
      end
    end)

    {:ok, slash: slash_pid}
  end

  test "/new-session --agent cc --dir /tmp/test succeeds through the full slash path" do
    {:ok, slash} = Esr.AdminSessionProcess.slash_handler_ref()

    envelope = %{
      "principal_id" => @test_principal,
      "payload" => %{
        "text" => "/new-session --agent cc --dir /tmp/test",
        "chat_id" => "oc_smoke",
        "thread_id" => "om_smoke"
      }
    }

    send(slash, {:slash_cmd, envelope, self()})

    assert_receive {:reply, text}, 2_000
    assert text =~ "session started:", "expected session-started reply, got: #{text}"

    # Extract the session_id from "session started: <sid>".
    [_, sid] = Regex.run(~r/session started: (\S+)/, text)

    # SessionProcess came up with the expected args.
    state = Esr.SessionProcess.state(sid)
    assert state.agent_name == "cc"
    assert state.dir == "/tmp/test"
    assert state.metadata.principal_id == @test_principal

    # Controlled-failure assertion for PR-2: the agent's pipeline peers
    # (CCProcess, TmuxProcess) are NOT spawned — they arrive in PR-3.
    # The peers DynamicSupervisor is therefore empty.
    peers_sup = Esr.Session.supervisor_name(sid)
    assert DynamicSupervisor.count_children(peers_sup).active == 0
  end

  test "/new-session without --agent returns a readable error reply" do
    {:ok, slash} = Esr.AdminSessionProcess.slash_handler_ref()

    envelope = %{
      "principal_id" => @test_principal,
      "payload" => %{
        "text" => "/new-session --dir /tmp/x",
        "chat_id" => "oc_smoke",
        "thread_id" => "om_smoke"
      }
    }

    send(slash, {:slash_cmd, envelope, self()})

    assert_receive {:reply, text}, 1_000
    assert text =~ "requires --agent",
           "expected --agent missing error, got: #{text}"
  end

  test "/new-session without matching capability returns an error reply" do
    {:ok, slash} = Esr.AdminSessionProcess.slash_handler_ref()

    envelope = %{
      "principal_id" => @test_principal_nocap,
      "payload" => %{
        "text" => "/new-session --agent cc --dir /tmp/y",
        "chat_id" => "oc_smoke",
        "thread_id" => "om_smoke"
      }
    }

    send(slash, {:slash_cmd, envelope, self()})

    assert_receive {:reply, text}, 1_000

    # Dispatcher rejects the cast before Session.New runs (see
    # module-level "Drift from expansion doc"); text carries the
    # Dispatcher's "unauthorized" marker rather than AgentNew's
    # "missing_capabilities". Either way, the user gets a structured
    # error — never a crash — which is the spec §P2-13 intent.
    assert text =~ "error:", "expected an error reply, got: #{text}"

    assert text =~ "unauthorized" or text =~ "missing_capabilities",
           "expected unauthorized/missing_capabilities, got: #{text}"
  end

  defp snapshot_grants do
    :ets.tab2list(:esr_capabilities_grants) |> Map.new()
  rescue
    _ -> %{}
  end

  # Borrowed verbatim from `Esr.Admin.DispatcherTest` — tests that
  # restart the whole Admin.Supervisor may race against siblings.
  defp ensure_admin_dispatcher do
    if Process.whereis(Esr.Admin.Dispatcher) == nil do
      _ = Supervisor.restart_child(Esr.Supervisor, Esr.Admin.Supervisor)

      if Process.whereis(Esr.Admin.Dispatcher) == nil do
        {:ok, _} = Esr.Admin.Supervisor.start_link([])
      end
    end

    :ok
  end
end

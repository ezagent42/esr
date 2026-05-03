defmodule Esr.Admin.Commands.Scope.NewTest do
  @moduledoc """
  P3-8.6 — `Esr.Admin.Commands.Scope.New` is the consolidated
  agent-session command (dispatcher kind `session_new`) after the D15
  collapse. Formerly `Session.AgentNew`; the branch-worktree command
  moved to `Session.BranchNew`.

  These tests cover:

    * arg validation (D11: agent required; D13: dir required)
    * agent resolution via `Esr.SessionRegistry.agent_def/1`
    * `capabilities_required` verification (D18) via the new
      `Esr.Resource.Capability.has_all?/2` helper — full coverage, total miss,
      partial miss
    * happy path: Session actually spawned under `Scope.Supervisor`
      with the submitter recorded in `metadata.principal_id`
    * PR-8 T2: chat_id/thread_id thread through as chat_thread_key
    * PR-8 T3: SessionRegistry binding for chat-bound sessions
    * PR-8 T4: chat-bound path dispatches to
      `Esr.Scope.Router.create_session/1` so the full pipeline spawns
      (FeishuChatProxy, CCProcess, PtyProcess); the admin-CLI
      "pending" branch retains the legacy `Scope.Supervisor` route
  """
  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Scope.New, as: SessionNew
  alias Esr.Resource.Capability.Grants

  setup do
    # App-level singletons (booted by Esr.Application).
    assert is_pid(Process.whereis(Esr.SessionRegistry))
    assert is_pid(Process.whereis(Esr.Scope.Supervisor))
    assert is_pid(Process.whereis(Grants))

    :ok =
      Esr.SessionRegistry.load_agents(
        Path.expand("../../../fixtures/agents/simple.yaml", __DIR__)
      )

    # PR-8 T4: Scope.Router is not (yet) a permanent application child,
    # so tests that exercise the create_session path start it under the
    # ExUnit supervisor and tear it down per-test. Idempotent — if a
    # sibling test already stood it up and it survived, reuse it.
    if Process.whereis(Esr.Scope.Router) == nil do
      start_supervised!(Esr.Scope.Router)
    end

    # Snapshot + restore grants so tests don't bleed into siblings.
    prior =
      try do
        :ets.tab2list(:esr_capabilities_grants) |> Map.new()
      rescue
        _ -> %{}
      end

    on_exit(fn ->
      Grants.load_snapshot(prior)

      # Clean up any sessions we spawned.
      case Process.whereis(Esr.Scope.Supervisor) do
        nil ->
          :ok

        pid ->
          for {_, child, _, _} <- DynamicSupervisor.which_children(pid) do
            if is_pid(child), do: DynamicSupervisor.terminate_child(pid, child)
          end
      end
    end)

    :ok
  end

  describe "execute/1 arg validation" do
    test "missing agent → invalid_args" do
      cmd = %{"submitted_by" => "ou_alice", "args" => %{"dir" => "/tmp/x"}}
      assert {:error, %{"type" => "invalid_args", "message" => msg}} = SessionNew.execute(cmd)
      assert msg =~ "agent"
    end

    test "missing dir → invalid_args" do
      cmd = %{"submitted_by" => "ou_alice", "args" => %{"agent" => "cc"}}
      assert {:error, %{"type" => "invalid_args", "message" => msg}} = SessionNew.execute(cmd)
      assert msg =~ "dir"
    end

    test "malformed command (no args) → invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} = SessionNew.execute(%{})
    end
  end

  describe "execute/1 agent resolution" do
    test "unknown agent → unknown_agent error" do
      Grants.load_snapshot(%{"ou_alice" => ["*"]})

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"agent" => "does-not-exist", "dir" => "/tmp/x"}
      }

      assert {:error, %{"type" => "unknown_agent", "agent" => "does-not-exist"}} =
               SessionNew.execute(cmd)
    end
  end

  describe "execute/1 capabilities_required verification (D18)" do
    test "principal with every required cap → session created" do
      Grants.load_snapshot(%{
        "ou_alice" => [
          "session:default/create",
          "pty:default/spawn",
          "handler:cc_adapter_runner/invoke"
        ]
      })

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"agent" => "cc", "dir" => "/tmp/x"}
      }

      assert {:ok, %{"session_id" => sid, "agent" => "cc"}} = SessionNew.execute(cmd)
      assert is_binary(sid)

      # Scope.Process is actually up, with the submitter recorded.
      state = Esr.Scope.Process.state(sid)
      assert state.agent_name == "cc"
      assert state.metadata.principal_id == "ou_alice"
    end

    test "principal missing ALL caps → missing_capabilities, Session NOT created" do
      Grants.load_snapshot(%{"ou_bob" => []})

      before_count = DynamicSupervisor.count_children(Esr.Scope.Supervisor).active

      cmd = %{
        "submitted_by" => "ou_bob",
        "args" => %{"agent" => "cc", "dir" => "/tmp/x"}
      }

      assert {:error, %{"type" => "missing_capabilities", "caps" => missing}} =
               SessionNew.execute(cmd)

      # simple.yaml's cc agent declares the full canonical set.
      assert Enum.sort(missing) == [
               "handler:cc_adapter_runner/invoke",
               "session:default/create",
               "pty:default/spawn"
             ]

      after_count = DynamicSupervisor.count_children(Esr.Scope.Supervisor).active
      assert after_count == before_count, "no new Session should have been created"
    end

    test "principal with PARTIAL caps → missing_capabilities lists only the gap" do
      # Has session:default/create + pty:default/spawn but NOT handler/invoke.
      Grants.load_snapshot(%{
        "ou_carol" => ["session:default/create", "pty:default/spawn"]
      })

      before_count = DynamicSupervisor.count_children(Esr.Scope.Supervisor).active

      cmd = %{
        "submitted_by" => "ou_carol",
        "args" => %{"agent" => "cc", "dir" => "/tmp/x"}
      }

      assert {:error, %{"type" => "missing_capabilities", "caps" => ["handler:cc_adapter_runner/invoke"]}} =
               SessionNew.execute(cmd)

      after_count = DynamicSupervisor.count_children(Esr.Scope.Supervisor).active
      assert after_count == before_count, "no new Session should have been created"
    end

    test "wildcard grant is accepted for every declared cap" do
      Grants.load_snapshot(%{"ou_wild" => ["*"]})

      cmd = %{
        "submitted_by" => "ou_wild",
        "args" => %{"agent" => "cc", "dir" => "/tmp/x"}
      }

      assert {:ok, %{"session_id" => _sid}} = SessionNew.execute(cmd)
    end
  end

  describe "execute/2 chat_thread_key threading (PR-8 T2)" do
    test "chat_id + thread_id args flow into Scope.Router.create_session params" do
      # PR-8 T4: the chat-bound path now dispatches via `create_session_fn`
      # (default `&Esr.Scope.Router.create_session/1`). Stub it so we can
      # observe the params shape without spawning the real pipeline.
      Grants.load_snapshot(%{"ou_admin" => ["*"]})

      cmd = %{
        "submitted_by" => "ou_admin",
        "args" => %{
          "agent" => "cc",
          "dir" => "/tmp/t2",
          "chat_id" => "oc_A",
          "thread_id" => "om_B"
        }
      }

      test_pid = self()

      stub = fn params ->
        send(test_pid, {:create_session_called, params})
        {:ok, "stub-sid-t2"}
      end

      assert {:ok, %{"session_id" => "stub-sid-t2", "agent" => "cc"}} =
               SessionNew.execute(cmd, create_session_fn: stub)

      assert_receive {:create_session_called,
                      %{chat_id: "oc_A", thread_id: "om_B", agent: "cc", dir: "/tmp/t2"}}
    end

    test "omitted chat_id/thread_id falls back to {\"pending\", \"pending\"} and skips Scope.Router" do
      # The admin-CLI branch (no chat context) must NOT hit Scope.Router
      # — that would pollute the registry's pending slot. Stub both hooks
      # and assert only `start_session_fn` fires.
      Grants.load_snapshot(%{"ou_admin" => ["*"]})

      cmd = %{
        "submitted_by" => "ou_admin",
        "args" => %{"agent" => "cc", "dir" => "/tmp/t2"}
      }

      test_pid = self()

      start_stub = fn args ->
        send(test_pid, {:start_session_called, args})
        {:ok, spawn(fn -> :ok end)}
      end

      create_stub = fn params ->
        send(test_pid, {:create_session_called, params})
        {:ok, "should-not-fire"}
      end

      assert {:ok, %{"session_id" => _sid}} =
               SessionNew.execute(cmd,
                 start_session_fn: start_stub,
                 create_session_fn: create_stub
               )

      assert_receive {:start_session_called,
                      %{chat_thread_key: %{chat_id: "pending", app_id: "pending"}}}

      refute_received {:create_session_called, _}
    end

    test "real path stores chat_thread_key in Scope.Process state (pending branch)" do
      # PR-8 T2 + T4: end-to-end check through the legacy Scope.Supervisor
      # path. Without chat context, Session.New still falls through to
      # `Scope.Supervisor.start_session/1`; Scope.Process should still
      # record an empty chat_thread_key. The chat-bound path (exercised in
      # the T4 describe block) covers the Scope.Router leg.
      Grants.load_snapshot(%{"ou_admin" => ["*"]})

      cmd = %{
        "submitted_by" => "ou_admin",
        "args" => %{"agent" => "cc", "dir" => "/tmp/t2"}
      }

      assert {:ok, %{"session_id" => sid}} = SessionNew.execute(cmd)

      state = Esr.Scope.Process.state(sid)
      # PR-A T1 / PR-21λ: legacy admin-CLI path (no chat context) carries
      # an app_id slot mirroring the chat_id placeholder so the routing
      # key shape stays well-formed.
      assert state.chat_thread_key ==
               %{chat_id: "pending", app_id: "pending"}

      assert state.agent_name == "cc"
    end
  end

  describe "execute/1 SessionRegistry binding (PR-8 T3)" do
    test "chat_id + app_id args register the session under the real app_id" do
      # PR-8 T3 / T4 / PR-21λ-fix: Session.New must register the session
      # so `FeishuAppAdapter` lookups resolve to it on the next inbound.
      # The lookup uses `(chat_id, app_id)` where app_id is the adapter
      # instance id (e.g. "esr_dev_helper"). Pre-fix, Session.New dropped
      # args["app_id"] and let Scope.Router fall back to "default" —
      # inbound messages then missed every time. Regression guard: the
      # registration key must equal the adapter instance id, not the
      # "default" fallback.
      Grants.load_snapshot(%{"ou_admin" => ["*"]})

      cmd = %{
        "submitted_by" => "ou_admin",
        "args" => %{
          "agent" => "cc",
          "dir" => "/tmp/t3-bound",
          "chat_id" => "oc_T3",
          "thread_id" => "om_T3",
          "app_id" => "esr_dev_helper"
        }
      }

      assert {:ok, %{"session_id" => sid}} = SessionNew.execute(cmd)

      assert {:ok, ^sid, refs} =
               Esr.SessionRegistry.lookup_by_chat("oc_T3", "esr_dev_helper")

      # The "default" fallback slot must remain empty — proves the fix
      # threaded app_id rather than letting it default.
      assert :not_found = Esr.SessionRegistry.lookup_by_chat("oc_T3", "default")

      # Post-T4: refs is populated with the spawned pipeline peer pids.
      assert is_map(refs)

      on_exit(fn -> Esr.SessionRegistry.unregister_session(sid) end)
    end

    test "omitted chat_id/thread_id skips SessionRegistry registration (pending fallback)" do
      # When submitted via `esr admin submit session_new --arg agent=... --arg dir=...`
      # there's no chat context, so chat_thread_key stays `{"pending","pending"}`.
      # Registering those would clobber a single global slot and cause spurious
      # hits — skip instead.
      Grants.load_snapshot(%{"ou_admin" => ["*"]})

      cmd = %{
        "submitted_by" => "ou_admin",
        "args" => %{"agent" => "cc", "dir" => "/tmp/t3-pending"}
      }

      assert {:ok, %{"session_id" => sid}} = SessionNew.execute(cmd)

      assert :not_found =
               Esr.SessionRegistry.lookup_by_chat("pending", "pending"),
             "the pending placeholder must not end up in the registry"

      # The session itself is still up — registration skip doesn't prevent
      # the session from starting.
      state = Esr.Scope.Process.state(sid)
      assert state.agent_name == "cc"
    end

    test "registration happens after start_session; a second execute with same keys overwrites" do
      # Re-register semantics: the ETS table is a `:set`, so a second
      # registration for the same {chat_id, thread_id} overwrites. This
      # covers the "admin re-runs /new-session in the same thread" corner.
      Grants.load_snapshot(%{"ou_admin" => ["*"]})

      cmd1 = %{
        "submitted_by" => "ou_admin",
        "args" => %{
          "agent" => "cc",
          "dir" => "/tmp/t3-first",
          "chat_id" => "oc_T3_reuse",
          "thread_id" => "om_T3_reuse",
          "app_id" => "esr_dev_helper"
        }
      }

      assert {:ok, %{"session_id" => sid1}} = SessionNew.execute(cmd1)

      assert {:ok, ^sid1, _} =
               Esr.SessionRegistry.lookup_by_chat("oc_T3_reuse", "esr_dev_helper")

      cmd2 = put_in(cmd1["args"]["dir"], "/tmp/t3-second")
      assert {:ok, %{"session_id" => sid2}} = SessionNew.execute(cmd2)
      refute sid2 == sid1, "second execute yields a fresh session_id"

      assert {:ok, ^sid2, _} =
               Esr.SessionRegistry.lookup_by_chat("oc_T3_reuse", "esr_dev_helper")

      on_exit(fn ->
        Esr.SessionRegistry.unregister_session(sid1)
        Esr.SessionRegistry.unregister_session(sid2)
      end)
    end
  end

  describe "execute/1 Scope.Router pipeline spawn (PR-8 T4)" do
    @describetag :t4_session_router

    test "execute/1 routes through Scope.Router.create_session so pipeline peers spawn" do
      # PR-8 T4: post-rewire, Session.New must delegate to
      # Scope.Router.create_session/1 when chat context is present. That
      # path spawns the full agents.yaml `pipeline.inbound` — so the refs
      # map in SessionRegistry carries a real FeishuChatProxy pid instead
      # of an empty map. FeishuAppAdapter.handle_upstream/2 pattern-matches
      # `%{feishu_chat_proxy: pid}` and now actually fires.
      Grants.load_snapshot(%{"ou_admin" => ["*"]})

      cmd = %{
        "submitted_by" => "ou_admin",
        "args" => %{
          "agent" => "cc",
          "dir" => "/tmp/t4-router",
          "chat_id" => "oc_T4",
          "thread_id" => "om_T4",
          "app_id" => "cli_test"
        }
      }

      assert {:ok, %{"session_id" => sid}} = SessionNew.execute(cmd)

      # Post-T4 invariant: refs contains a real feishu_chat_proxy pid
      # spawned by Scope.Router.spawn_pipeline/3, not an empty map.
      assert {:ok, ^sid, %{feishu_chat_proxy: proxy_pid} = refs} =
               Esr.SessionRegistry.lookup_by_chat("oc_T4", "cli_test")

      assert is_pid(proxy_pid)
      assert Process.alive?(proxy_pid)

      # Sanity: the full CC chain from simple.yaml is present.
      assert is_pid(refs.cc_process)
      assert is_pid(refs.pty_process)

      on_exit(fn -> Esr.SessionRegistry.unregister_session(sid) end)
    end
  end
end

defmodule Esr.Commands.Session.NewTest do
  @moduledoc """
  P3-8.6 — `Esr.Commands.Session.New` is the consolidated
  agent-session command (dispatcher kind `session_new`) after the D15
  collapse. Formerly `Session.AgentNew`; the branch-worktree command
  moved to `Session.BranchNew`.

  Phase 5 cut-over (2026-05-10): `Session.New` no longer reads from
  `Esr.Entity.Agent.Registry.agent_def/1`. It resolves a SessionTemplate
  (explicit `template=` arg → operator-configured default →
  no_default_template error) and materializes the template via
  `Esr.SessionTemplate.Registry.materialize/2`. These tests register a
  feishu-cc-shaped template in setup so the spawn path produces the
  same canonical CC chain as the pre-cut agents.yaml fixture.

  These tests cover:

    * arg validation (D11: agent required; D13: dir required)
    * template resolution + materialization (Phase 5)
    * `capabilities_required` verification (D18) via the new
      `Esr.Resource.Capability.has_all?/2` helper — full coverage, total miss,
      partial miss
    * happy path: Session actually spawned under `Scope.Supervisor`
      with the submitter recorded in `metadata.principal_id`
    * PR-8 T2: chat_id/thread_id thread through as chat_thread_key
    * PR-8 T3: SessionRegistry binding for chat-bound sessions
    * PR-8 T4: chat-bound path dispatches to
      `Esr.Session.Router.create_session/1` so the full pipeline spawns
      (FeishuChatProxy, CCProcess, PtyProcess); the admin-CLI
      "pending" branch retains the legacy `Scope.Supervisor` route
  """
  use ExUnit.Case, async: false

  alias Esr.Commands.Session.New, as: SessionNew
  alias Esr.Resource.Capability.Grants
  alias Esr.SessionTemplate.Registry, as: TemplateRegistry

  defp feishu_cc_template do
    %Esr.SessionTemplate{
      schema_version: 1,
      name: "feishu-cc",
      description: "Feishu chat → Claude Code agent",
      dependencies: %{plugins: ["feishu", "claude_code"], bundles: []},
      channels: [
        %{alias: "in", kind: "feishu.chat_proxy", config: %{}},
        %{alias: "cc_mcp", kind: "claude_code.mcp_http", config: %{}}
      ],
      agents: [
        %{kind: "claude_code.cc", name: "<runtime>", consumes: ["cc_mcp"]}
      ],
      flow: %{inbound: [], outbound: []}
    }
  end

  defp tmp_session_plugin_dir do
    path =
      Path.join(System.tmp_dir!(), "esr_session_new_test_session_plugin_#{:rand.uniform(99_999_999)}")

    File.mkdir_p!(path)
    path
  end

  setup do
    # App-level singletons (booted by Esr.Application).
    assert is_pid(Process.whereis(Esr.Session.ChatRouting.Registry))
    assert is_pid(Process.whereis(Esr.Session.Supervisor))
    assert is_pid(Process.whereis(Grants))

    # Phase 5 cut-over: register a feishu-cc-shaped template instead of
    # seeding agents.yaml. Boot wires `Esr.SessionTemplate.Registry`
    # under the application supervisor so we just `clear` + `register`.
    case start_supervised(TemplateRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> TemplateRegistry.clear()
    end

    TemplateRegistry.register("feishu-cc", feishu_cc_template(),
      source: {:bundle, "feishu-cc"}
    )

    # Configure feishu-cc as the default template via a per-test plugin
    # config dir so we don't write into the operator's actual home.
    session_dir = tmp_session_plugin_dir()
    :ok = Esr.Session.DefaultTemplate.set("feishu-cc", global_path: session_dir)

    # Override the production default-template path for the duration of
    # the test by stubbing `Esr.Paths.plugin_global_dir("session")`.
    # The simplest seam: drop a config.yaml at the production path
    # (test env points at its own tmp ESRD_HOME) so `current/0` finds
    # it. The agent-CLI tests run with stable env per test setup.
    prod_dir = Esr.Paths.plugin_global_dir("session")
    File.mkdir_p!(prod_dir)
    File.write!(Path.join(prod_dir, "config.yaml"), ~s(default_template: "feishu-cc"\n))

    # PR-8 T4: Scope.Router is not (yet) a permanent application child,
    # so tests that exercise the create_session path start it under the
    # ExUnit supervisor and tear it down per-test. Idempotent — if a
    # sibling test already stood it up and it survived, reuse it.
    if Process.whereis(Esr.Session.Router) == nil do
      start_supervised!(Esr.Session.Router)
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
      TemplateRegistry.clear()
      File.rm_rf!(session_dir)
      File.rm_rf!(prod_dir)

      # Clean up any sessions we spawned.
      case Process.whereis(Esr.Session.Supervisor) do
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
    test "missing workspace + agent + no user-default → no_workspace_target (Phase 6 M-5)" do
      # Pre-M-5 (Phase 5.1 + 6.1): the resolution chain fell through to a
      # literal "default" workspace, so this case reached the capability
      # gate. M-5 (Phase 6) removed the literal-default layer — submitters
      # without a user-default now error out at resolution instead.
      #
      # ou_alice has no user-default link → :no_match → no_workspace_target.
      # (Renamed from no_workspace_resolvable in fix/chat-envelope-arg-fallback
      # so the error type matches the parallel /agent:add no_session_target.)
      Grants.load_snapshot(%{"ou_alice" => []})

      cmd = %{"submitted_by" => "ou_alice", "args" => %{"dir" => "/tmp/x"}}
      assert {:error, %{"type" => "no_workspace_target"}} = SessionNew.execute(cmd)
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

  describe "execute/1 template resolution (Phase 5)" do
    test "explicit unknown template → unknown_template error listing available" do
      Grants.load_snapshot(%{"ou_alice" => ["*"]})

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{
          "agent" => "cc",
          "dir" => "/tmp/x",
          "template" => "does-not-exist"
        }
      }

      assert {:error, %{"type" => "unknown_template", "message" => msg}} =
               SessionNew.execute(cmd)

      assert msg =~ "does-not-exist"
      # Available list should mention the registered fixture.
      assert msg =~ "feishu-cc"
    end

    test "no default + no explicit template → no_default_template error" do
      # Wipe both the registered template AND the operator-configured
      # default so resolve_template_name has nothing to fall back to.
      TemplateRegistry.clear()
      File.rm_rf!(Esr.Paths.plugin_global_dir("session"))

      Grants.load_snapshot(%{"ou_alice" => ["*"]})

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"agent" => "cc", "dir" => "/tmp/x"}
      }

      assert {:error, %{"type" => "no_default_template", "message" => msg}} =
               SessionNew.execute(cmd)

      assert msg =~ "/plugin:set"
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
      state = Esr.Session.Process.state(sid)
      assert state.agent_name == "cc"
      assert state.metadata.principal_id == "ou_alice"
    end

    test "principal missing ALL caps → missing_capabilities, Session NOT created" do
      Grants.load_snapshot(%{"ou_bob" => []})

      before_count = DynamicSupervisor.count_children(Esr.Session.Supervisor).active

      cmd = %{
        "submitted_by" => "ou_bob",
        "args" => %{"agent" => "cc", "dir" => "/tmp/x"}
      }

      assert {:error, %{"type" => "missing_capabilities", "message" => msg}} =
               SessionNew.execute(cmd)

      # Phase 3.3 grammar migration: caps list is interpolated into the
      # message (comma-joined) rather than carried as a separate key.
      # simple.yaml's cc agent declares the full canonical set.
      assert msg =~ "handler:cc_adapter_runner/invoke"
      assert msg =~ "pty:default/spawn"
      assert msg =~ "session:default/create"

      after_count = DynamicSupervisor.count_children(Esr.Session.Supervisor).active
      assert after_count == before_count, "no new Session should have been created"
    end

    test "principal with PARTIAL caps → missing_capabilities lists only the gap" do
      # Has session:default/create + pty:default/spawn but NOT handler/invoke.
      Grants.load_snapshot(%{
        "ou_carol" => ["session:default/create", "pty:default/spawn"]
      })

      before_count = DynamicSupervisor.count_children(Esr.Session.Supervisor).active

      cmd = %{
        "submitted_by" => "ou_carol",
        "args" => %{"agent" => "cc", "dir" => "/tmp/x"}
      }

      assert {:error, %{"type" => "missing_capabilities", "message" => msg}} =
               SessionNew.execute(cmd)

      # Phase 3.3 grammar migration: only the gap should appear in the
      # message; sister caps held by the principal must NOT.
      assert msg =~ "handler:cc_adapter_runner/invoke"
      refute msg =~ "session:default/create"
      refute msg =~ "pty:default/spawn"

      after_count = DynamicSupervisor.count_children(Esr.Session.Supervisor).active
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
      # (default `&Esr.Session.Router.create_session/1`). Stub it so we can
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

      state = Esr.Session.Process.state(sid)
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
               Esr.Session.ChatRouting.Registry.lookup_by_chat("oc_T3", "esr_dev_helper")

      # The "default" fallback slot must remain empty — proves the fix
      # threaded app_id rather than letting it default.
      assert :not_found = Esr.Session.ChatRouting.Registry.lookup_by_chat("oc_T3", "default")

      # Post-T4: refs is populated with the spawned pipeline peer pids.
      assert is_map(refs)

      on_exit(fn -> Esr.Session.ChatRouting.Registry.unregister_session(sid) end)
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
               Esr.Session.ChatRouting.Registry.lookup_by_chat("pending", "pending"),
             "the pending placeholder must not end up in the registry"

      # The session itself is still up — registration skip doesn't prevent
      # the session from starting.
      state = Esr.Session.Process.state(sid)
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
               Esr.Session.ChatRouting.Registry.lookup_by_chat("oc_T3_reuse", "esr_dev_helper")

      cmd2 = put_in(cmd1["args"]["dir"], "/tmp/t3-second")
      assert {:ok, %{"session_id" => sid2}} = SessionNew.execute(cmd2)
      refute sid2 == sid1, "second execute yields a fresh session_id"

      assert {:ok, ^sid2, _} =
               Esr.Session.ChatRouting.Registry.lookup_by_chat("oc_T3_reuse", "esr_dev_helper")

      on_exit(fn ->
        Esr.Session.ChatRouting.Registry.unregister_session(sid1)
        Esr.Session.ChatRouting.Registry.unregister_session(sid2)
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
               Esr.Session.ChatRouting.Registry.lookup_by_chat("oc_T4", "cli_test")

      assert is_pid(proxy_pid)
      assert Process.alive?(proxy_pid)

      # Sanity: the full CC chain from simple.yaml is present.
      assert is_pid(refs.cc_process)
      assert is_pid(refs.pty_process)

      on_exit(fn -> Esr.Session.ChatRouting.Registry.unregister_session(sid) end)
    end
  end

  # ---------------------------------------------------------------------------
  # Commit 2a — behaviours restored from the deleted 103-LOC `Session.New`
  # ---------------------------------------------------------------------------
  #
  # Spec rev-3 §0 of the cleanup PR assumed the canonical 449-LOC
  # `Session.New` (formerly `Scope.New`) already covered everything the
  # 103-LOC `Session.New` (PR #248-era) did. Implementation review
  # surfaced three behaviours lost in the merge:
  #
  #   1. `<data_dir>/sessions/<sid>/session.json` write
  #   2. `(owner_user, name)` uniqueness gate via
  #      `:esr_resource_session_name_index` ETS
  #   3. Explicit chat-attach (subsumed by Router's `register_session/3`
  #      for the chat-bound path; gated to fire only when Router didn't
  #      already bind so peer refs aren't clobbered)
  #
  # Each describe block below pins one of those behaviours back as a
  # regression guard.

  describe "session.json persistence (commit 2a)" do
    @describetag :session_persistence

    setup do
      tmp =
        Path.join(System.tmp_dir!(), "esr_session_new_persist_#{:rand.uniform(99_999_999)}")

      File.mkdir_p!(Path.join(tmp, "sessions"))

      prev_home = System.get_env("ESRD_HOME")
      prev_inst = System.get_env("ESR_INSTANCE")
      System.put_env("ESRD_HOME", tmp)
      System.put_env("ESR_INSTANCE", "default")

      # Phase 5 cut-over: replicate the outer setup's default-template
      # write into the new ESRD_HOME so `Esr.Session.DefaultTemplate.current/0`
      # finds `feishu-cc` once env is overridden.
      session_dir = Esr.Paths.plugin_global_dir("session")
      File.mkdir_p!(session_dir)
      File.write!(Path.join(session_dir, "config.yaml"), ~s(default_template: "feishu-cc"\n))

      # The Session.Registry caches `data_dir` only at call time
      # (`Esr.Paths.runtime_home/0`), so no reload is required — the
      # next `create_session/2` call picks up the new env. Just clear
      # the name-index ETS so prior tests don't bleed name conflicts in.
      try do
        :ets.delete_all_objects(:esr_resource_session_name_index)
      rescue
        ArgumentError -> :ok
      end

      on_exit(fn ->
        if prev_home, do: System.put_env("ESRD_HOME", prev_home), else: System.delete_env("ESRD_HOME")
        if prev_inst, do: System.put_env("ESR_INSTANCE", prev_inst), else: System.delete_env("ESR_INSTANCE")
        File.rm_rf!(tmp)

        try do
          :ets.delete_all_objects(:esr_resource_session_name_index)
        rescue
          ArgumentError -> :ok
        end
      end)

      {:ok, tmp: tmp}
    end

    test "writes <data_dir>/sessions/<sid>/session.json after spawn", %{tmp: tmp} do
      Grants.load_snapshot(%{"ou_persist" => ["*"]})

      cmd = %{
        "submitted_by" => "ou_persist",
        "args" => %{"agent" => "cc", "dir" => "/tmp/persist", "name" => "persist-#{:rand.uniform(99_999)}"}
      }

      assert {:ok, %{"session_id" => sid}} = SessionNew.execute(cmd)

      session_json = Path.join([tmp, "default", "sessions", sid, "session.json"])
      assert File.exists?(session_json), "expected #{session_json} to be written"

      doc = session_json |> File.read!() |> Jason.decode!()
      assert doc["id"] == sid
      assert doc["owner_user"] == "ou_persist"
    end

    test "session.json carries the owner-supplied name verbatim", %{tmp: tmp} do
      Grants.load_snapshot(%{"ou_persist" => ["*"]})
      name = "named-session-#{:rand.uniform(99_999)}"

      cmd = %{
        "submitted_by" => "ou_persist",
        "args" => %{"agent" => "cc", "dir" => "/tmp/persist-named", "name" => name}
      }

      assert {:ok, %{"session_id" => sid}} = SessionNew.execute(cmd)

      doc =
        [tmp, "default", "sessions", sid, "session.json"]
        |> Path.join()
        |> File.read!()
        |> Jason.decode!()

      assert doc["name"] == name
    end

    test "Session.Registry get_by_id resolves the freshly-spawned sid" do
      # Independent of data_dir layout: the in-memory ETS row must be
      # inserted by `persist_session_record/4` so subsequent lookups
      # (e.g. /session:list, /session:show) find the new session.
      Grants.load_snapshot(%{"ou_persist" => ["*"]})
      name = "registry-#{:rand.uniform(99_999)}"

      cmd = %{
        "submitted_by" => "ou_persist",
        "args" => %{"agent" => "cc", "dir" => "/tmp/persist-reg", "name" => name}
      }

      assert {:ok, %{"session_id" => sid}} = SessionNew.execute(cmd)
      assert {:ok, struct} = Esr.Resource.Session.Registry.get_by_id(sid)
      assert struct.id == sid
      assert struct.owner_user == "ou_persist"
      assert struct.name == name
    end
  end

  describe "(owner_user, name) uniqueness (commit 2a)" do
    @describetag :session_name_uniqueness

    setup do
      tmp =
        Path.join(System.tmp_dir!(), "esr_session_new_unique_#{:rand.uniform(99_999_999)}")

      File.mkdir_p!(Path.join(tmp, "sessions"))

      prev_home = System.get_env("ESRD_HOME")
      prev_inst = System.get_env("ESR_INSTANCE")
      System.put_env("ESRD_HOME", tmp)
      System.put_env("ESR_INSTANCE", "default")

      # Phase 5 cut-over: replicate the outer setup's default-template
      # write into the new ESRD_HOME (see persist describe above).
      session_dir = Esr.Paths.plugin_global_dir("session")
      File.mkdir_p!(session_dir)
      File.write!(Path.join(session_dir, "config.yaml"), ~s(default_template: "feishu-cc"\n))

      try do
        :ets.delete_all_objects(:esr_resource_session_name_index)
      rescue
        ArgumentError -> :ok
      end

      on_exit(fn ->
        if prev_home, do: System.put_env("ESRD_HOME", prev_home), else: System.delete_env("ESRD_HOME")
        if prev_inst, do: System.put_env("ESR_INSTANCE", prev_inst), else: System.delete_env("ESR_INSTANCE")
        File.rm_rf!(tmp)

        try do
          :ets.delete_all_objects(:esr_resource_session_name_index)
        rescue
          ArgumentError -> :ok
        end
      end)

      :ok
    end

    test "duplicate (owner_user, name) returns session_name_taken" do
      Grants.load_snapshot(%{"ou_dup" => ["*"]})
      name = "dup-name-#{:rand.uniform(99_999)}"

      cmd = %{
        "submitted_by" => "ou_dup",
        "args" => %{"agent" => "cc", "dir" => "/tmp/dup1", "name" => name}
      }

      assert {:ok, %{"session_id" => _sid}} = SessionNew.execute(cmd)

      # Spawn-counts before the duplicate-attempt — the gate is supposed
      # to fail BEFORE allocating a second supervisor subtree.
      before_count = DynamicSupervisor.count_children(Esr.Session.Supervisor).active

      cmd2 = put_in(cmd, ["args", "dir"], "/tmp/dup2")
      assert {:error, %{"type" => "session_name_taken", "message" => msg}} =
               SessionNew.execute(cmd2)

      assert msg =~ name
      assert msg =~ "ou_dup"

      after_count = DynamicSupervisor.count_children(Esr.Session.Supervisor).active

      assert after_count == before_count,
             "session_name_taken must short-circuit before spawning a second supervisor"
    end

    test "same name under a different owner is allowed" do
      Grants.load_snapshot(%{
        "ou_alpha" => ["*"],
        "ou_beta" => ["*"]
      })

      name = "shared-name-#{:rand.uniform(99_999)}"

      cmd1 = %{
        "submitted_by" => "ou_alpha",
        "args" => %{"agent" => "cc", "dir" => "/tmp/share1", "name" => name}
      }

      cmd2 = %{
        "submitted_by" => "ou_beta",
        "args" => %{"agent" => "cc", "dir" => "/tmp/share2", "name" => name}
      }

      assert {:ok, %{"session_id" => sid1}} = SessionNew.execute(cmd1)
      assert {:ok, %{"session_id" => sid2}} = SessionNew.execute(cmd2)

      refute sid1 == sid2,
             "two distinct owners with the same name must yield distinct sessions"
    end

    test "missing name skips the uniqueness gate (admin-CLI path)" do
      # Admin submits like `esr admin submit session_new --arg agent=cc
      # --arg dir=/tmp/x` don't carry a name. The 103-LOC version
      # rejected such commands outright; the merged 449-LOC accepts
      # them (legacy admin-CLI use case) and the uniqueness gate has
      # to be a no-op so it stays compatible.
      Grants.load_snapshot(%{"ou_admin" => ["*"]})

      cmd = %{
        "submitted_by" => "ou_admin",
        "args" => %{"agent" => "cc", "dir" => "/tmp/no-name"}
      }

      assert {:ok, %{"session_id" => sid}} = SessionNew.execute(cmd)
      assert is_binary(sid)
    end
  end

  describe "chat-attach interplay (commit 2a)" do
    @describetag :chat_attach_interplay

    test "chat-bound spawn preserves Router-side peer refs" do
      # Regression guard: an earlier draft of the commit-2a fix called
      # `ChatScope.Registry.attach_session/3` unconditionally after a
      # successful spawn, which clobbered the 3-tuple
      # `{key, sid, refs}` row Router writes via `register_session/3`
      # with the 2-tuple `{key, %{current: sid, attached: …}}` shape.
      # `lookup_by_chat/2` then returned `{:ok, sid, %{}}` — empty
      # refs — and the next inbound `FeishuAppAdapter.handle_upstream/2`
      # missed `%{feishu_chat_proxy: pid}`. The fix gates the explicit
      # attach on whether the slot already carries this sid; this test
      # locks that gate in.
      Grants.load_snapshot(%{"ou_admin" => ["*"]})

      cmd = %{
        "submitted_by" => "ou_admin",
        "args" => %{
          "agent" => "cc",
          "dir" => "/tmp/2a-attach",
          "chat_id" => "oc_2A",
          "thread_id" => "om_2A",
          "app_id" => "esr_dev_helper",
          "name" => "attach-keep-refs-#{:rand.uniform(99_999)}"
        }
      }

      assert {:ok, %{"session_id" => sid}} = SessionNew.execute(cmd)

      assert {:ok, ^sid, refs} =
               Esr.Session.ChatRouting.Registry.lookup_by_chat("oc_2A", "esr_dev_helper")

      # Router populates these via spawn_pipeline/3; the explicit
      # attach must NOT have wiped them.
      assert is_pid(refs.feishu_chat_proxy),
             "expected feishu_chat_proxy pid in refs, got #{inspect(refs)}"

      assert is_pid(refs.cc_process)
      assert is_pid(refs.pty_process)

      on_exit(fn -> Esr.Session.ChatRouting.Registry.unregister_session(sid) end)
    end
  end
end

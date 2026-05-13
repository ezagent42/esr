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
        %{alias: "cc_mcp", kind: "claude_code.mcp_stdio", config: %{}}
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

    # Phase 6 (2026-05-10): the AgentDefBuilder now sources channel +
    # agent kind contributions from the plugin registries. In the test
    # env `enabled_plugins = []`, so nothing populates them at boot —
    # register the kinds the feishu-cc template references explicitly.
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
      "mcp_stdio",
      Esr.Plugins.ClaudeCode.Channels.Mcp,
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
    test "missing workspace + no dir + no user-default → no_workspace_target (Phase 6 M-5)" do
      # The M-5 user-default chain is the only remaining workspace
      # discovery path (2026-05-12 cutover removed the "agent given →
      # skip resolution" backdoor). With no explicit workspace, no
      # explicit dir, and no user-default for the submitter, every layer
      # of the fallback ladder misses → no_workspace_target.
      Grants.load_snapshot(%{"ou_alice" => []})

      cmd = %{"submitted_by" => "ou_alice", "args" => %{"agent" => "cc"}}
      assert {:error, %{"type" => "no_workspace_target"}} = SessionNew.execute(cmd)
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

  describe "execute/1 :pipeline_incomplete surface (PR-2 2026-05-11)" do
    test "AgentSpawner integrity terminal surfaces as pipeline_incomplete chat error" do
      # PR-2 spec rev-3 §PR-2: when do_create returns
      # {:error, :pipeline_incomplete} (post-spawn integrity check
      # detected a declared inbound stage that didn't materialize),
      # Session.New must surface a specific :pipeline_incomplete error
      # rather than smuggling it through the generic
      # :session_start_failed with `inspect(:pipeline_incomplete)`.
      Grants.load_snapshot(%{"ou_admin" => ["*"]})

      cmd = %{
        "submitted_by" => "ou_admin",
        "args" => %{
          "agent" => "cc",
          "dir" => "/tmp/incomplete",
          "chat_id" => "oc_inc",
          "thread_id" => "om_inc",
          "app_id" => "app_inc"
        }
      }

      # Stub the chat-bound path so we don't need to wire up real
      # AgentSpawner state for the integrity check to fire.
      stub = fn _params -> {:error, :pipeline_incomplete} end

      assert {:error, %{"type" => "pipeline_incomplete", "message" => msg}} =
               SessionNew.execute(cmd, create_session_fn: stub)

      assert msg =~ "未全部 spawn"
    end

    test "non-:pipeline_incomplete errors still route to session_start_failed" do
      Grants.load_snapshot(%{"ou_admin" => ["*"]})

      cmd = %{
        "submitted_by" => "ou_admin",
        "args" => %{
          "agent" => "cc",
          "dir" => "/tmp/other",
          "chat_id" => "oc_o",
          "thread_id" => "om_o",
          "app_id" => "app_o"
        }
      }

      stub = fn _params -> {:error, :some_other_failure} end

      assert {:error, %{"type" => "session_start_failed", "message" => msg}} =
               SessionNew.execute(cmd, create_session_fn: stub)

      assert msg =~ "some_other_failure"
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

      assert {:ok, ^sid} =
               Esr.Session.ChatRouting.Registry.current_session("oc_T3", "esr_dev_helper")

      # The "default" fallback slot must remain empty — proves the fix
      # threaded app_id rather than letting it default.
      assert :not_found = Esr.Session.ChatRouting.Registry.current_session("oc_T3", "default")

      # Post-PR-3 Task 3.3b: peer refs no longer live in the ETS row;
      # the per-peer presence is verified by other tests via ActorQuery.

      on_exit(fn -> Esr.Session.ChatRouting.Registry.detach_session_by_id(sid) end)
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
               Esr.Session.ChatRouting.Registry.current_session("pending", "pending"),
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

      assert {:ok, ^sid1} =
               Esr.Session.ChatRouting.Registry.current_session("oc_T3_reuse", "esr_dev_helper")

      cmd2 = put_in(cmd1["args"]["dir"], "/tmp/t3-second")
      assert {:ok, %{"session_id" => sid2}} = SessionNew.execute(cmd2)
      refute sid2 == sid1, "second execute yields a fresh session_id"

      # PR-3 Task 3.3b: second /new-session re-attaches the chat slot to
      # the new sid (attach_session promotes the new uuid as current
      # because the slot already had sid1 attached — sid2 becomes the
      # additional attached entry; legacy register_session/3 silently
      # overwrote, but the unified attach API preserves both as attached
      # and keeps the FIRST as current). We assert the current_session is
      # still sid1 to lock that semantic difference; switching is via
      # /session:switch.
      assert {:ok, ^sid1} =
               Esr.Session.ChatRouting.Registry.current_session("oc_T3_reuse", "esr_dev_helper")

      on_exit(fn ->
        Esr.Session.ChatRouting.Registry.detach_session_by_id(sid1)
        Esr.Session.ChatRouting.Registry.detach_session_by_id(sid2)
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

      # Post-PR-3 Task 3.3b invariant: chat-routing carries the sid only,
      # peer pids are reachable via ActorQuery's role index.
      assert {:ok, ^sid} =
               Esr.Session.ChatRouting.Registry.current_session("oc_T4", "cli_test")

      assert {:ok, proxy_pid} = Esr.ActorQuery.fcp_for_session(sid)
      assert is_pid(proxy_pid)
      assert Process.alive?(proxy_pid)

      # Sanity: the full CC chain from simple.yaml is present.
      assert [cc_pid | _] = Esr.ActorQuery.list_by_role(sid, :cc_process)
      assert is_pid(cc_pid)
      assert [pty_pid | _] = Esr.ActorQuery.list_by_role(sid, :pty_process)
      assert is_pid(pty_pid)

      on_exit(fn -> Esr.Session.ChatRouting.Registry.detach_session_by_id(sid) end)
    end
  end

  # ---------------------------------------------------------------------------
  # 2026-05-10 — Phase 5 regression: live operator typed
  # `/session:new name=test-cc` (no agent=, no dir=, no workspace=) in a
  # Feishu chat with no workspace bound yet, and got `error: invalid_args`
  # instead of a session. Root cause: the with-chain ran `validate_args`
  # FIRST, which required both `agent` and `dir`. Phase 5 made the
  # SessionTemplate authoritative for the spawn pipeline, so neither is
  # mandatory at the command-input layer anymore — agent defaults via
  # the slash route's `arg :agent, default: "cc"`, and `dir` falls back
  # to the resolved workspace's first folder.
  # ---------------------------------------------------------------------------
  describe "Phase 5 template-driven defaults (live-bug regression 2026-05-10)" do
    @describetag :phase5_template_defaults

    test "args carry only name + workspace=ws → dir auto-derived from workspace.folders[0]" do
      # The original bug: operator types `/session:new name=test-cc` with
      # a chat-bound workspace whose folders[0].path is the repo checkout.
      # Pre-fix this errored at validate_args("cc", nil) with "dir
      # required". Post-fix `resolve_dir/1` reads workspace.folders[0].path
      # and threads it to the spawn.
      Grants.load_snapshot(%{"ou_alice" => ["*"]})

      ws =
        Esr.Test.WorkspaceFixture.build(
          name: "test-cc-ws",
          owner: "alice",
          folders: [%{path: "/tmp/test-cc-repo"}]
        )

      :ok = Esr.Uri.Compat.workspace_put(ws)

      test_pid = self()

      stub = fn params ->
        send(test_pid, {:create_session_called, params})
        {:ok, "stub-sid-derived"}
      end

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{
          "agent" => "cc",
          "name" => "test-cc-derived-#{:rand.uniform(99_999)}",
          "workspace" => "test-cc-ws",
          "chat_id" => "oc_PH5",
          "thread_id" => "om_PH5",
          "app_id" => "cli_test_ph5"
        }
      }

      assert {:ok, %{"session_id" => "stub-sid-derived"}} =
               SessionNew.execute(cmd, create_session_fn: stub)

      assert_receive {:create_session_called, %{dir: "/tmp/test-cc-repo"}}

      on_exit(fn -> Esr.Test.WorkspaceFixture.delete!("test-cc-ws") end)
    end

    test "default template auto-elected: `/session:new name=foo` (no agent, no template) succeeds when workspace resolves" do
      # The exact symptom from the live bug, reproduced under test:
      # operator types `/session:new name=test-cc` in a chat with a
      # user-default workspace. Pre-fix this errored. Post-fix resolves
      # workspace via M-5 chain, derives dir from workspace.folders[0],
      # and uses the auto-elected default template (feishu-cc, set up in
      # the outer setup block).
      Grants.load_snapshot(%{"ou_alice" => ["*"]})

      # ou_alice has no chat-default; rely on the user-default chain.
      ws =
        Esr.Test.WorkspaceFixture.build(
          name: "alice-default-ws",
          owner: "alice",
          folders: [%{path: "/tmp/alice-default-repo"}]
        )

      :ok = Esr.Uri.Compat.workspace_put(ws)

      # The M-5 user-default lookup keys off `username`, not `submitted_by`.
      # Provide a User.Registry entry + per-user default workspace link.
      Esr.Test.UserFixture.load_snapshot(
        %{
          "alice" => %Esr.Entity.User.Struct{username: "alice", feishu_ids: ["ou_alice"]}
        },
        %{"alice" => "alice-id"}
      )

      :ok = Esr.Uri.Compat.set_default_workspace_for_user_name("alice", ws.id)

      test_pid = self()

      stub = fn params ->
        send(test_pid, {:create_session_called, params})
        {:ok, "stub-sid-live-bug"}
      end

      session_name = "test-cc-#{:rand.uniform(99_999)}"

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{
          # `submitter_username` is what slash_handler resolves from
          # envelope.user_id via Esr.Entity.User.Registry; the M-5
          # user-default lookup (Esr.Commands.Workspace.Resolve) keys
          # off it.
          "submitter_username" => "alice",
          "name" => session_name,
          # The live bug surfaced from a Feishu slash, so chat context
          # is present even when workspace+dir+agent aren't.
          "chat_id" => "oc_live_bug",
          "thread_id" => "om_live_bug",
          "app_id" => "esr_dev_helper"
        }
      }

      assert {:ok, %{"session_id" => "stub-sid-live-bug", "workspace" => "alice-default-ws"}} =
               SessionNew.execute(cmd, create_session_fn: stub)

      # `dir` derived from workspace.folders[0]; `agent` defaulted to "cc"
      # because workspace was resolved (line 145 fallback).
      assert_receive {:create_session_called, %{dir: "/tmp/alice-default-repo", agent: "cc"}}

      on_exit(fn ->
        Esr.Test.WorkspaceFixture.delete!("alice-default-ws")
        Esr.Test.UserFixture.load_snapshot(%{}, %{})
      end)
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
  #      :session entity rows in :esr_uri_store (PR-3 URI identity)
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
      # PR-3 (URI identity): the old `:esr_resource_session_name_index`
      # ETS is gone. Session entities now live as URI store rows; clear
      # the entire :session kind to mimic the legacy wipe.
      try do
        if Process.whereis(Esr.Uri.Store), do: Esr.Uri.Store.delete_all_by_kind(:session)
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
      assert {:ok, struct} = Esr.Uri.Compat.session_by_uuid(sid)
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

      # PR-3 (URI identity): the old `:esr_resource_session_name_index`
      # ETS is gone. Session entities now live as URI store rows; clear
      # the entire :session kind to mimic the legacy wipe.
      try do
        if Process.whereis(Esr.Uri.Store), do: Esr.Uri.Store.delete_all_by_kind(:session)
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

      assert {:ok, ^sid} =
               Esr.Session.ChatRouting.Registry.current_session("oc_2A", "esr_dev_helper")

      # PR-3 Task 3.3b: peer refs no longer live in ETS. Router still
      # populates the role index via spawn_pipeline/3 → ActorQuery.
      assert {:ok, fcp_pid} = Esr.ActorQuery.fcp_for_session(sid)
      assert is_pid(fcp_pid)

      assert [cc_pid | _] = Esr.ActorQuery.list_by_role(sid, :cc_process)
      assert is_pid(cc_pid)

      assert [pty_pid | _] = Esr.ActorQuery.list_by_role(sid, :pty_process)
      assert is_pid(pty_pid)

      on_exit(fn -> Esr.Session.ChatRouting.Registry.detach_session_by_id(sid) end)
    end
  end
end

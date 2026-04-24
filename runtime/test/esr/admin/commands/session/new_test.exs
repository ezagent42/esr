defmodule Esr.Admin.Commands.Session.NewTest do
  @moduledoc """
  P3-8.6 — `Esr.Admin.Commands.Session.New` is the consolidated
  agent-session command (dispatcher kind `session_new`) after the D15
  collapse. Formerly `Session.AgentNew`; the branch-worktree command
  moved to `Session.BranchNew`.

  These tests cover:

    * arg validation (D11: agent required; D13: dir required)
    * agent resolution via `Esr.SessionRegistry.agent_def/1`
    * `capabilities_required` verification (D18) via the new
      `Esr.Capabilities.has_all?/2` helper — full coverage, total miss,
      partial miss
    * happy path: Session actually spawned under `SessionsSupervisor`
      with the submitter recorded in `metadata.principal_id`
  """
  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Session.New, as: SessionNew
  alias Esr.Capabilities.Grants

  setup do
    # App-level singletons (booted by Esr.Application).
    assert is_pid(Process.whereis(Esr.SessionRegistry))
    assert is_pid(Process.whereis(Esr.SessionsSupervisor))
    assert is_pid(Process.whereis(Grants))

    :ok =
      Esr.SessionRegistry.load_agents(
        Path.expand("../../../fixtures/agents/simple.yaml", __DIR__)
      )

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
      case Process.whereis(Esr.SessionsSupervisor) do
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
          "tmux:default/spawn",
          "handler:cc_adapter_runner/invoke"
        ]
      })

      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"agent" => "cc", "dir" => "/tmp/x"}
      }

      assert {:ok, %{"session_id" => sid, "agent" => "cc"}} = SessionNew.execute(cmd)
      assert is_binary(sid)

      # SessionProcess is actually up, with the submitter recorded.
      state = Esr.SessionProcess.state(sid)
      assert state.agent_name == "cc"
      assert state.metadata.principal_id == "ou_alice"
    end

    test "principal missing ALL caps → missing_capabilities, Session NOT created" do
      Grants.load_snapshot(%{"ou_bob" => []})

      before_count = DynamicSupervisor.count_children(Esr.SessionsSupervisor).active

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
               "tmux:default/spawn"
             ]

      after_count = DynamicSupervisor.count_children(Esr.SessionsSupervisor).active
      assert after_count == before_count, "no new Session should have been created"
    end

    test "principal with PARTIAL caps → missing_capabilities lists only the gap" do
      # Has session:default/create + tmux:default/spawn but NOT handler/invoke.
      Grants.load_snapshot(%{
        "ou_carol" => ["session:default/create", "tmux:default/spawn"]
      })

      before_count = DynamicSupervisor.count_children(Esr.SessionsSupervisor).active

      cmd = %{
        "submitted_by" => "ou_carol",
        "args" => %{"agent" => "cc", "dir" => "/tmp/x"}
      }

      assert {:error, %{"type" => "missing_capabilities", "caps" => ["handler:cc_adapter_runner/invoke"]}} =
               SessionNew.execute(cmd)

      after_count = DynamicSupervisor.count_children(Esr.SessionsSupervisor).active
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
    test "chat_id + thread_id args flow into chat_thread_key" do
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

      stub = fn args ->
        send(test_pid, {:start_session_called, args})
        {:ok, spawn(fn -> :ok end)}
      end

      assert {:ok, %{"session_id" => sid, "agent" => "cc"}} =
               SessionNew.execute(cmd, start_session_fn: stub)

      assert is_binary(sid)

      assert_receive {:start_session_called,
                      %{chat_thread_key: %{chat_id: "oc_A", thread_id: "om_B"}}}
    end

    test "omitted chat_id/thread_id falls back to {\"pending\", \"pending\"}" do
      Grants.load_snapshot(%{"ou_admin" => ["*"]})

      cmd = %{
        "submitted_by" => "ou_admin",
        "args" => %{"agent" => "cc", "dir" => "/tmp/t2"}
      }

      test_pid = self()

      stub = fn args ->
        send(test_pid, {:start_session_called, args})
        {:ok, spawn(fn -> :ok end)}
      end

      assert {:ok, %{"session_id" => _sid}} =
               SessionNew.execute(cmd, start_session_fn: stub)

      assert_receive {:start_session_called,
                      %{chat_thread_key: %{chat_id: "pending", thread_id: "pending"}}}
    end

    test "real start_session/1 path stores chat_thread_key in SessionProcess state" do
      # PR-8 T2: end-to-end check through the real SessionsSupervisor path.
      # SessionRegistry ETS binding is performed by SessionRouter.create_session/2
      # (not SessionsSupervisor.start_session/1), so this assertion scopes to
      # the SessionProcess state — the narrowest point where "the chat_id
      # reached the per-session layer" can be observed without pulling in
      # PeerFactory / SessionRouter (PR-3+ concerns).
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

      assert {:ok, %{"session_id" => sid}} = SessionNew.execute(cmd)

      state = Esr.SessionProcess.state(sid)
      assert state.chat_thread_key == %{chat_id: "oc_A", thread_id: "om_B"}
    end
  end
end

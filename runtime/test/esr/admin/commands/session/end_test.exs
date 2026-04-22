defmodule Esr.Admin.Commands.Session.EndTest do
  @moduledoc """
  P3-9.2 — `Esr.Admin.Commands.Session.End` (the new, post-D15-collapse
  agent-session teardown command; dispatcher kind `session_end`) tears
  down a Session supervisor tree by delegating to
  `Esr.SessionRouter.end_session/1`.

  Before PR-3 P3-9 this module name held the legacy branch-worktree
  teardown logic, now renamed to `Session.BranchEnd` (dispatcher kind
  `session_branch_end`; tests in `branch_end_test.exs`).

  These tests cover:

    * happy path: real `SessionRouter.create_session` → `End.execute`
      tears the Session supervisor down and unregisters it.
    * `unknown_session` surface from the router propagates back to the
      caller as `{:error, %{"type" => "unknown_session", ...}}`.
    * arg validation: missing `session_id` → `invalid_args`.
  """
  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Session.End, as: SessionEnd
  alias Esr.Capabilities.Grants

  setup do
    # App-level singletons must already be up for SessionRouter to
    # do real work.
    assert is_pid(Process.whereis(Esr.SessionRegistry))
    assert is_pid(Process.whereis(Esr.SessionsSupervisor))
    assert is_pid(Process.whereis(Grants))

    :ok =
      Esr.SessionRegistry.load_agents(
        Path.expand("../../../fixtures/agents/simple.yaml", __DIR__)
      )

    # Ensure SessionRouter is running. Started as a supervised child in
    # app boot, but some test runs skip it — start-if-missing keeps the
    # suite self-contained.
    case Process.whereis(Esr.SessionRouter) do
      nil -> {:ok, _} = Esr.SessionRouter.start_link([])
      _ -> :ok
    end

    prior =
      try do
        :ets.tab2list(:esr_capabilities_grants) |> Map.new()
      rescue
        _ -> %{}
      end

    on_exit(fn ->
      Grants.load_snapshot(prior)

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

  describe "execute/1 happy path" do
    test "ends an existing agent-session via SessionRouter" do
      Grants.load_snapshot(%{"ou_alice" => ["*"]})

      {:ok, sid} =
        Esr.SessionRouter.create_session(%{
          agent: "cc",
          dir: "/tmp",
          principal_id: "ou_alice",
          chat_id: "oc_end_happy_#{System.unique_integer([:positive])}",
          thread_id: "om_end_happy_#{System.unique_integer([:positive])}"
        })

      # Supervisor exists pre-teardown.
      via = {:via, Registry, {Esr.Session.Registry, {:session_sup, sid}}}
      pre_pid = GenServer.whereis(via)
      assert is_pid(pre_pid) and Process.alive?(pre_pid)

      cmd = %{"submitted_by" => "ou_alice", "args" => %{"session_id" => sid}}

      assert {:ok, %{"session_id" => ^sid, "ended" => true}} = SessionEnd.execute(cmd)

      # Supervisor is gone.
      assert GenServer.whereis(via) == nil
    end
  end

  describe "execute/1 error paths" do
    test "unknown session_id → {:error, %{\"type\" => \"unknown_session\"}}" do
      cmd = %{
        "submitted_by" => "ou_alice",
        "args" => %{"session_id" => "NONEXISTENT_#{System.unique_integer([:positive])}"}
      }

      assert {:error, %{"type" => "unknown_session"}} = SessionEnd.execute(cmd)
    end

    test "missing args.session_id → invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} =
               SessionEnd.execute(%{"submitted_by" => "ou_alice", "args" => %{}})
    end

    test "empty session_id string → invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} =
               SessionEnd.execute(%{
                 "submitted_by" => "ou_alice",
                 "args" => %{"session_id" => ""}
               })
    end

    test "malformed command (no args key) → invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} = SessionEnd.execute(%{})
    end
  end
end

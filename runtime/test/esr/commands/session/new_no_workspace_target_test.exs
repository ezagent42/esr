defmodule Esr.Commands.Session.NewNoWorkspaceTargetTest do
  @moduledoc """
  fix/chat-envelope-arg-fallback — `Esr.Commands.Session.New` returns
  `no_workspace_target` (not `invalid_args`) when the workspace
  resolver chain is fully exhausted.

  Three layers must all miss:
    1. No explicit `workspace=` in args.
    2. No chat-current workspace binding for `(chat_id, app_id)`.
    3. No user-default workspace for the submitter.

  This is distinct from `invalid_args`, which still fires for
  shape-malformed input (missing `agent`/`dir`, no args at all). The
  rename + structured message lets the operator see which gate failed
  — the fix is to BIND a workspace, not to rephrase the args.
  """

  use ExUnit.Case, async: false

  alias Esr.Commands.Session.New, as: SessionNew
  alias Esr.Resource.Capability.Grants

  setup do
    # App-level singletons (booted by Esr.Application). Same pattern as
    # the existing new_test.exs so we don't bring up a second app.
    assert is_pid(Process.whereis(Esr.Session.ChatRouting.Registry))
    assert is_pid(Process.whereis(Grants))

    :ok =
      Esr.Entity.Agent.Registry.load_agents(
        Path.expand("../../fixtures/agents/simple.yaml", __DIR__)
      )

    # Snapshot + restore grants so this test doesn't bleed into siblings.
    prior =
      try do
        :ets.tab2list(:esr_capabilities_grants) |> Map.new()
      rescue
        _ -> %{}
      end

    on_exit(fn -> Grants.load_snapshot(prior) end)
    :ok
  end

  describe "no_workspace_target — full resolver chain miss" do
    test "no workspace= AND no chat binding AND no user-default → no_workspace_target" do
      # ou_no_target has no user-default link. No chat_id/app_id in args
      # → chat-default layer skips. No explicit workspace=. All three
      # layers miss → :no_match → structured `no_workspace_target`.
      Grants.load_snapshot(%{"ou_no_target" => []})

      cmd = %{"submitted_by" => "ou_no_target", "args" => %{"dir" => "/tmp/x"}}

      assert {:error, %{"type" => "no_workspace_target", "message" => msg}} =
               SessionNew.execute(cmd)

      # Message names every missing layer so the operator sees which
      # bind action fixes it. Pin the keywords so a careless rewording
      # doesn't silently degrade operator UX.
      assert msg =~ "no explicit workspace="
      assert msg =~ "no chat-current binding"
      assert msg =~ "no user-default"
      assert msg =~ "/workspace:bind-chat"
      assert msg =~ "/user:use"
    end

    test "no_workspace_target is NOT returned when args= are entirely absent" do
      # Empty/malformed input is still `invalid_args` — that's the
      # catch-all clause's contract. The new error is reserved for
      # "args present, resolver chain fully exhausted" so callers can
      # distinguish "bind a workspace" from "fix your command shape".
      assert {:error, %{"type" => "invalid_args"}} = SessionNew.execute(%{})
    end

    test "missing dir but workspace resolvable → invalid_args (dir gate, not resolver)" do
      # Sanity: when the resolver SUCCEEDS (agent given short-circuits
      # the chain), the dir gate's `invalid_args` still fires. Proves
      # the rename didn't cannibalise downstream validation.
      cmd = %{"submitted_by" => "ou_no_target", "args" => %{"agent" => "cc"}}
      assert {:error, %{"type" => "invalid_args", "message" => msg}} = SessionNew.execute(cmd)
      assert msg =~ "dir"
    end
  end
end

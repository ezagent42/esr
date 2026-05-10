defmodule Esr.Commands.Agent.AddTest do
  @moduledoc """
  Phase 6 (2026-05-10): `/agent:add`'s type validation reads from
  `Esr.Plugin.AgentKindRegistry` (populated by Esr.Plugin.Loader from
  each enabled plugin's manifest `agent_kinds:` block) instead of the
  retired `Esr.Entity.Agent.Registry` agents.yaml cache.

  Setup ensures a `claude_code.cc` agent_kind is registered so the
  bare-name `"cc"` lookup resolves via
  `AgentKindRegistry.find_unqualified/1`.
  """
  use ExUnit.Case, async: false
  alias Esr.Commands.Agent.Add
  alias Esr.Plugin.AgentKindRegistry

  @sess "11111111-1111-4111-8111-aaaaaaaaaaaa"

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    case Process.whereis(AgentKindRegistry) do
      nil -> start_supervised!(AgentKindRegistry)
      _ -> :ok
    end

    # Idempotent: re-registers if app boot already populated it; sets up
    # a known-good kind otherwise.
    AgentKindRegistry.register("claude_code", "cc", %{
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

    :ok
  end

  test "without a running Scope: returns structured spawn_failed error" do
    name = "dev-#{:rand.uniform(9999)}"
    cmd = %{"args" => %{"session_id" => @sess, "type" => "cc", "name" => name, "config" => %{}}}
    assert {:error, %{"type" => "spawn_failed"}} = Add.execute(cmd)
  end

  test "missing session_id and no chat context: returns no_session_target" do
    # fix/chat-envelope-arg-fallback: when `type` + `name` are present
    # but neither `session_id=` nor a resolvable chat-current target
    # exist, the operator submitted a command with no session to act on.
    # Surface `no_session_target` so the message points them at the fix
    # (`/session:new` or explicit `session_id=`); reserve `invalid_args`
    # for actually-empty / shape-malformed input.
    assert {:error, %{"type" => "no_session_target"}} =
             Add.execute(%{"args" => %{"type" => "cc", "name" => "x"}})
  end

  test "unknown agent type: returns unknown_agent_type" do
    cmd = %{"args" => %{"session_id" => @sess, "type" => "no_such", "name" => "x", "config" => %{}}}
    assert {:error, %{"type" => "unknown_agent_type"}} = Add.execute(cmd)
  end
end

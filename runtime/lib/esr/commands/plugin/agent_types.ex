defmodule Esr.Commands.Plugin.AgentTypes do
  @moduledoc """
  `/plugin:agent-types` — list every agent type declared by enabled
  plugins (sourced from `Esr.Plugin.AgentKindRegistry.list_keys/0`,
  populated at boot from each plugin manifest's `agent_kinds:` block).

  Replaces the old `/agent:list` semantics; `/agent:list` now lists
  agent INSTANCES inside chat-current session (Phase C Task C.7).

  Phase 6 (2026-05-10): pre-Phase-6 this command read from
  `Esr.Entity.Agent.Registry.list_agents/0` (agents.yaml cache);
  post-Phase-6 the source is the plugin manifest registry. Output
  shape changed from bare names (`"cc"`) to qualified
  `<plugin>.<kind>` (`"claude_code.cc"`) — there is no longer a
  single-namespace yaml so qualifying is unambiguous.

  Spec rev-3 §4.2 (row "/plugin:agent-types"), D6.
  """

  use Esr.Commands.Meta

  command :plugin_agent_types do
    slash         "/plugin:agent-types"
    category      "Plugins"
    description   "列出 enabled plugins 声明的所有 agent 类型（旧 /agent:list 的语义）"
    permission    nil
    requires_user_binding      false
    requires_workspace_binding false
  end

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(_cmd) do
    text =
      case Esr.Plugin.AgentKindRegistry.list_keys() do
        [] ->
          "no agent types declared (no enabled plugin ships an agent_kinds: block)"

        keys ->
          lines = Enum.map_join(keys, "\n", fn key -> "  - #{key}" end)
          "available agent types:\n#{lines}"
      end

    {:ok, %{"text" => text}}
  end
end

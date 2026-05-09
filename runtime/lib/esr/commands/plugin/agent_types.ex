defmodule Esr.Commands.Plugin.AgentTypes do
  @moduledoc """
  `/plugin:agent-types` — list every agent type declared by enabled
  plugins (compiled via `Esr.Entity.Agent.Registry.list_agents/0`).

  Replaces the old `/agent:list` semantics; `/agent:list` now lists
  agent INSTANCES inside chat-current session (Phase C Task C.7).

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
      case Esr.Entity.Agent.Registry.list_agents() do
        [] ->
          "no agents loaded (agents.yaml empty or not found)"

        names ->
          lines = Enum.map_join(names, "\n", fn n -> "  - #{n}" end)
          "available agent types:\n#{lines}"
      end

    {:ok, %{"text" => text}}
  end
end

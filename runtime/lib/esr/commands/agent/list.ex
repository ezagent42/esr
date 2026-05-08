defmodule Esr.Commands.Agent.List do
  @moduledoc """
  `/list-agents` slash command — list every agent name compiled from
  `agents.yaml` (PR-21κ, 2026-04-30).

  Reads `Esr.Entity.Agent.Registry.list_agents/0`.

  ## Latent bug fixed by this module

  Pre-PR-21κ, `/list-agents` was parsed by SlashHandler as
  `kind: "agent_list"`, but `Esr.Admin.Dispatcher.run_command/2` had no
  branch for that kind — it fell through to the default error path and
  the operator received `unknown_kind`. PR-21κ wires `agent_list` to
  this module via `slash-routes.yaml`'s `command_module` field, so the
  kind now resolves cleanly.
  """

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
          "available agents:\n#{lines}"
      end

    {:ok, %{"text" => text}}
  end
end

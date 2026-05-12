defmodule Esr.Commands.Agent.List do
  @moduledoc """
  `/agent:list` — list agent INSTANCES in chat-current session.

  Reads `Esr.Session.ChatRouting.Registry.current_session/2` to find the
  current session UUID, then `Esr.Entity.Agent.InstanceRegistry.list/2`
  to enumerate the per-session `%Instance{}` records.

  Spec rev-3 §4.2 (`/agent:list` repurposed), I3. The old type-catalog
  semantics moved to `Esr.Commands.Plugin.AgentTypes`.
  """

  use Esr.Commands.Meta

  command :agent_list do
    slash         "/agent:list"
    category      "Agents"
    description   "列当前 chat 当前 session 内运行的 agent 实例"
    permission    nil
    requires_user_binding      true
    requires_workspace_binding false

    error :invalid_args, "/agent:list requires chat context (chat_id + app_id in envelope)"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Session.ChatRouting.Registry, as: ChatRouting

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"chat_id" => chat_id, "app_id" => app_id}})
      when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
    case ChatRouting.current_session(chat_id, app_id) do
      {:ok, sid} ->
        agents =
          Esr.Uri.Compat.list_agents_in_session(sid)
          |> Enum.map(fn inst ->
            %{
              "name" => inst.name,
              "type" => inst.type,
              "actor_ids" => %{
                "cc" => get_in(inst.actor_ids || %{}, [:cc]),
                "pty" => get_in(inst.actor_ids || %{}, [:pty])
              }
            }
          end)

        {:ok, %{"chat_id" => chat_id, "session_id" => sid, "agents" => agents}}

      :not_found ->
        {:ok, %{"chat_id" => chat_id, "session_id" => nil, "agents" => []}}
    end
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end
end

defmodule Esr.Commands.Agent.Primary do
  @moduledoc """
  `/agent:primary` — read-only: show the primary agent name for the
  chat-current session. Net-new in spec rev-3 §4.2.
  """

  use Esr.Commands.Meta

  command :agent_primary do
    slash         "/agent:primary"
    category      "Agents"
    description   "显示当前 session 的 primary agent"
    permission    nil
    requires_user_binding      true
    requires_workspace_binding false

    error :no_current_session, "no session attached to this chat; /session:bind-chat first"
    error :invalid_args,       "/agent:primary requires chat context"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Session.ChatRouting.Registry, as: ChatRouting

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"chat_id" => chat_id, "app_id" => app_id}})
      when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
    # PR-4 URI identity migration (2026-05-12): primary_agent_uuid/1
    # returns the agent UUID; chain agent_by_uuid/1 to recover the
    # display name for the operator-facing reply.
    with {:ok, sid} <- ChatRouting.current_session(chat_id, app_id),
         {:ok, agent_uuid} <- Esr.Uri.Compat.primary_agent_uuid(sid),
         {:ok, %{name: name}} <- Esr.Uri.Compat.agent_by_uuid(agent_uuid) do
      {:ok, %{"session_id" => sid, "primary" => name}}
    else
      :not_found ->
        Render.error(__MODULE__.command_meta(), :no_current_session)
    end
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end
end

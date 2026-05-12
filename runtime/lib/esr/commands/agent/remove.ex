defmodule Esr.Commands.Agent.Remove do
  @moduledoc """
  Remove an agent instance (`/agent:remove`).

  Cannot remove the primary agent — the caller must set another agent as
  primary first via `/agent:set-primary`.

  Replaces the legacy `Esr.Commands.Session.RemoveAgent`; logic identical
  (spec rev-3 §4.2 D1 hard-cutover). The old session/remove_agent.ex is
  deleted in Task C.9.
  """

  use Esr.Commands.Meta

  command :agent_remove do
    slash         "/agent:remove"
    category      "Agents"
    description   "从当前 session 删除 agent；不能删 primary（先 set-primary）"
    permission    "session:default/spawn"
    requires_user_binding      true
    requires_workspace_binding false

    arg :name, required: true, doc: "agent name to remove"

    error :cannot_remove_primary,
          "cannot remove primary agent '%{name}'; use /agent:set-primary to promote another agent first"
    error :not_found,    "no agent named '%{name}' in session '%{session_id}'"
    error :invalid_args, "/agent:remove requires args.session_id and args.name (non-empty strings)"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Uri.Compat

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"session_id" => sid, "name" => name}})
      when is_binary(sid) and sid != "" and is_binary(name) and name != "" do
    case Compat.remove_instance(sid, name) do
      :ok ->
        {:ok, %{"action" => "removed", "session_id" => sid, "name" => name}}

      {:error, :cannot_remove_primary} ->
        Render.error(__MODULE__.command_meta(), :cannot_remove_primary, %{name: name})

      {:error, :not_found} ->
        Render.error(__MODULE__.command_meta(), :not_found, %{name: name, session_id: sid})
    end
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end
end

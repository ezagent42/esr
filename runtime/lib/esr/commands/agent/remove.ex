defmodule Esr.Commands.Agent.Remove do
  @moduledoc """
  Remove an agent instance (`/agent:remove`).

  Cannot remove the primary agent — the caller must set another agent as
  primary first via `/agent:set-primary`.

  Replaces the legacy `Esr.Commands.Session.RemoveAgent`; logic identical
  (spec rev-3 §4.2 D1 hard-cutover). The old session/remove_agent.ex is
  deleted in Task C.9.
  """

  @behaviour Esr.Role.Control

  alias Esr.Entity.Agent.InstanceRegistry

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"session_id" => sid, "name" => name}})
      when is_binary(sid) and sid != "" and is_binary(name) and name != "" do
    case InstanceRegistry.remove_instance(sid, name) do
      :ok ->
        {:ok, %{"action" => "removed", "session_id" => sid, "name" => name}}

      {:error, :cannot_remove_primary} ->
        {:error,
         %{
           "type" => "cannot_remove_primary",
           "message" =>
             "cannot remove primary agent '#{name}'; use /agent:set-primary to promote another agent first"
         }}

      {:error, :not_found} ->
        {:error,
         %{
           "type" => "not_found",
           "message" => "no agent named '#{name}' in session '#{sid}'"
         }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "/agent:remove requires args.session_id and args.name (non-empty strings)"
     }}
  end
end

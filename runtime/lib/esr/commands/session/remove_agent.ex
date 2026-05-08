defmodule Esr.Commands.Session.RemoveAgent do
  @moduledoc """
  Remove an agent instance from a session (`/session:remove-agent`).

  Cannot remove the primary agent — the caller must set another agent as
  primary first via `/session:set-primary`.

  Slash-routes YAML entry added in Phase 6.
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
             "cannot remove primary agent '#{name}'; use /session:set-primary to promote another agent first"
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
       "message" => "remove_agent requires args.session_id and args.name (non-empty strings)"
     }}
  end
end

defmodule Esr.Commands.Agent.Rename do
  @moduledoc """
  `/agent:rename` — rename an agent instance within a session. Net-new
  in rev-3 §4.2 (no `/session:rename-agent` predecessor).

  Args: `session_id`, `name`, `new_name` (all required).
  """

  @behaviour Esr.Role.Control

  alias Esr.Entity.Agent.InstanceRegistry

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"session_id" => sid, "name" => name, "new_name" => new_name}})
      when is_binary(sid) and sid != "" and
             is_binary(name) and name != "" and
             is_binary(new_name) and new_name != "" do
    case InstanceRegistry.rename_instance(sid, name, new_name) do
      :ok ->
        {:ok,
         %{
           "action" => "renamed",
           "session_id" => sid,
           "old_name" => name,
           "new_name" => new_name
         }}

      {:error, :not_found} ->
        {:error,
         %{
           "type" => "not_found",
           "message" => "agent '#{name}' not found in session '#{sid}'"
         }}

      {:error, :duplicate_agent_name} ->
        {:error,
         %{
           "type" => "duplicate_agent_name",
           "message" =>
             "agent '#{new_name}' already exists in session '#{sid}' (pick a different name)"
         }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" =>
         "/agent:rename requires args.session_id, args.name, and args.new_name"
     }}
  end
end

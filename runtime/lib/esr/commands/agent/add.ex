defmodule Esr.Commands.Agent.Add do
  @moduledoc """
  `/agent:add` — add an agent instance to chat-current session (or
  explicit `session_id=`). Replaces `/session:add-agent`.

  Logic identical to the legacy `Esr.Commands.Session.AddAgent`; the
  spec rename (§4.2 row `/agent:add`, D1 hard-cutover) renames the
  module + slash; the old session/add_agent.ex is deleted in Task C.9.

  Validates type against `Esr.Entity.Agent.Registry.list_agents/0` and
  rejects unknown types with `{:error, %{"type" => "unknown_agent_type"}}`.
  """

  @behaviour Esr.Role.Control

  alias Esr.Entity.Agent.InstanceRegistry

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"session_id" => sid, "type" => type, "name" => name} = args})
      when is_binary(sid) and sid != "" and
             is_binary(type) and type != "" and
             is_binary(name) and name != "" do
    config = Map.get(args, "config", %{})

    with :ok <- validate_agent_type(type) do
      case InstanceRegistry.add_instance_and_spawn(%{
             session_id: sid,
             type: type,
             name: name,
             config: config
           }) do
        {:ok, %{actor_ids: actor_ids}} ->
          {:ok,
           %{
             "action" => "added",
             "session_id" => sid,
             "type" => type,
             "name" => name,
             "actor_ids" => %{
               "cc" => actor_ids.cc,
               "pty" => actor_ids.pty
             }
           }}

        {:error, {:duplicate_agent_name, n}} ->
          {:error,
           %{
             "type" => "duplicate_agent_name",
             "message" =>
               "agent name '#{n}' already exists in session '#{sid}' (pick a different name)"
           }}

        {:error, {:spawn_failed, reason}} ->
          {:error,
           %{
             "type" => "spawn_failed",
             "message" =>
               "failed to spawn agent subtree for '#{name}' in session '#{sid}': #{inspect(reason)}"
           }}
      end
    else
      {:error, :unknown_agent_type} ->
        known = known_agent_types()

        {:error,
         %{
           "type" => "unknown_agent_type",
           "message" =>
             "agent type '#{type}' is not declared in any enabled plugin; known types: #{Enum.join(known, ", ")}"
         }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" =>
         "/agent:add requires args.session_id, args.type, and args.name (all non-empty strings)"
     }}
  end

  defp validate_agent_type(type) do
    if type in known_agent_types(), do: :ok, else: {:error, :unknown_agent_type}
  end

  defp known_agent_types do
    case Esr.Entity.Agent.Registry.list_agents() do
      names when is_list(names) -> names
      _ -> []
    end
  end
end

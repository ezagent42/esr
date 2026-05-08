defmodule Esr.Commands.Session.AddAgent do
  @moduledoc """
  Add an agent instance to a session (`/session:add-agent`).

  Validates the requested agent type against the enabled plugin manifest
  via `Esr.Entity.Agent.Registry.list_agents/0`. Rejects unknown types
  with `{:error, %{"type" => "unknown_agent_type"}}`.

  Name uniqueness is enforced globally within the session regardless of
  type (spec Q7=B): two agents with the same name cannot coexist in one
  session even if their types differ.

  Slash-routes YAML entry added in Phase 6.
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
         "add_agent requires args.session_id, args.type, and args.name (all non-empty strings)"
     }}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_agent_type(type) do
    known = known_agent_types()
    if type in known, do: :ok, else: {:error, :unknown_agent_type}
  end

  defp known_agent_types do
    case Esr.Entity.Agent.Registry.list_agents() do
      names when is_list(names) -> names
      _ -> []
    end
  end
end

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
  alias Esr.Session.ChatRouting.Registry, as: ChatRouting

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  # Chat-current fallback: when operator omits `session_id=` but the
  # SlashHandler injected chat_id+app_id from the envelope, resolve the
  # chat-current session via `ChatRouting.current_session/2` (same helper
  # /agent:list and /agent:primary use) and recurse with session_id added.
  # If the chat has no current session, surface `no_session_target` so the
  # operator sees which gate failed instead of a generic invalid_args.
  def execute(
        %{
          "args" =>
            %{"chat_id" => chat_id, "app_id" => app_id, "type" => type, "name" => name} = args
        } = cmd
      )
      when is_binary(chat_id) and chat_id != "" and
             is_binary(app_id) and app_id != "" and
             is_binary(type) and type != "" and
             is_binary(name) and name != "" and
             not is_map_key(args, "session_id") do
    case ChatRouting.current_session(chat_id, app_id) do
      {:ok, sid} ->
        execute(put_in(cmd, ["args", "session_id"], sid))

      :not_found ->
        {:error,
         %{
           "type" => "no_session_target",
           "message" =>
             "no chat-current session and session_id= not provided; " <>
               "use /session:new or pass session_id=<uuid>"
         }}
    end
  end

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

  # Args present (type+name) but no session_id and no chat_id+app_id to
  # resolve from. Operator submitted a malformed command (no target).
  # Surface `no_session_target` so the message points them at the fix
  # (`/session:new` or explicit `session_id=`); reserve `invalid_args`
  # for actually-empty / shape-malformed input handled by the catch-all.
  def execute(%{"args" => %{"type" => type, "name" => name}})
      when is_binary(type) and type != "" and is_binary(name) and name != "" do
    {:error,
     %{
       "type" => "no_session_target",
       "message" =>
         "no chat-current session and session_id= not provided; " <>
           "use /session:new or pass session_id=<uuid>"
     }}
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" =>
         "/agent:add requires args.type and args.name (non-empty strings); " <>
           "session_id= is optional when chat-current is set"
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

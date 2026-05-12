defmodule Esr.Commands.Agent.Add do
  @moduledoc """
  `/agent:add` — add an agent instance to chat-current session (or
  explicit `session_id=`). Replaces `/session:add-agent`.

  Logic identical to the legacy `Esr.Commands.Session.AddAgent`; the
  spec rename (§4.2 row `/agent:add`, D1 hard-cutover) renames the
  module + slash; the old session/add_agent.ex is deleted in Task C.9.

  Phase 6 (2026-05-10): type validation sourced from
  `Esr.Plugin.AgentKindRegistry` (the plugin manifest agent_kinds
  registry that replaced the agents.yaml cache). Both qualified
  `<plugin>.<kind>` and bare-name forms are accepted — bare names are
  resolved via `AgentKindRegistry.find_unqualified/1`, which returns
  `{:error, :ambiguous}` if two plugins both declare the name (let-it-
  crash: surface the ambiguity to the operator).
  """

  use Esr.Commands.Meta

  command :agent_add do
    slash         "/agent:add"
    category      "Agents"
    description   "向当前 session 添加 agent 实例；name 须全局唯一"
    permission    "session:default/spawn"
    requires_user_binding      true
    requires_workspace_binding false

    arg :type, required: true, doc: "agent type declared by an enabled plugin"
    arg :name, required: true, doc: "globally-unique instance name"

    error :no_session_target,
          "no chat-current session and session_id= not provided; use /session:new or pass session_id=<uuid>"
    error :duplicate_agent_name,
          "agent name '%{name}' already exists in session '%{session_id}' (pick a different name)"
    error :spawn_failed,
          "failed to spawn agent subtree for '%{name}' in session '%{session_id}': %{reason}"
    error :unknown_agent_type,
          "agent type '%{type}' is not declared in any enabled plugin; known types: %{known}"
    error :invalid_args,
          "/agent:add requires args.type and args.name (non-empty strings); session_id= is optional when chat-current is set"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Session.ChatRouting.Registry, as: ChatRouting
  alias Esr.Uri.Compat

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
        Render.error(__MODULE__.command_meta(), :no_session_target)
    end
  end

  def execute(%{"args" => %{"session_id" => sid, "type" => type, "name" => name} = args})
      when is_binary(sid) and sid != "" and
             is_binary(type) and type != "" and
             is_binary(name) and name != "" do
    config = Map.get(args, "config", %{})

    with :ok <- validate_agent_type(type) do
      case Compat.add_instance_and_spawn(%{
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
          Render.error(__MODULE__.command_meta(), :duplicate_agent_name, %{
            name: n,
            session_id: sid
          })

        {:error, {:spawn_failed, reason}} ->
          Render.error(__MODULE__.command_meta(), :spawn_failed, %{
            name: name,
            session_id: sid,
            reason: inspect(reason)
          })
      end
    else
      {:error, :unknown_agent_type} ->
        Render.error(__MODULE__.command_meta(), :unknown_agent_type, %{
          type: type,
          known: Enum.join(known_agent_types(), ", ")
        })
    end
  end

  # Args present (type+name) but no session_id and no chat_id+app_id to
  # resolve from. Operator submitted a malformed command (no target).
  # Surface `no_session_target` so the message points them at the fix
  # (`/session:new` or explicit `session_id=`); reserve `invalid_args`
  # for actually-empty / shape-malformed input handled by the catch-all.
  def execute(%{"args" => %{"type" => type, "name" => name}})
      when is_binary(type) and type != "" and is_binary(name) and name != "" do
    Render.error(__MODULE__.command_meta(), :no_session_target)
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end

  # Phase 6 (2026-05-10): type validation sourced from
  # `Esr.Plugin.AgentKindRegistry`. Accepts both qualified
  # `<plugin>.<kind>` and bare-name forms; bare names are resolved
  # via `find_unqualified/1` which surfaces ambiguity loudly.
  defp validate_agent_type(type) do
    cond do
      String.contains?(type, ".") ->
        case Esr.Plugin.AgentKindRegistry.lookup(type) do
          {:ok, _spec} -> :ok
          :not_found -> {:error, :unknown_agent_type}
        end

      true ->
        case Esr.Plugin.AgentKindRegistry.find_unqualified(type) do
          {:ok, _key, _spec} -> :ok
          :not_found -> {:error, :unknown_agent_type}
          {:error, {:ambiguous, _keys}} -> {:error, :unknown_agent_type}
        end
    end
  end

  defp known_agent_types do
    Esr.Plugin.AgentKindRegistry.list_keys()
  end
end

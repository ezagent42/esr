defmodule Esr.Commands.Agent.AddSession do
  @moduledoc """
  `/agent:add-session` — attach an existing agent instance to another
  session. Phase 7 (2026-05-10) of the SessionTemplate + Channel
  migration. After this command, the same `%Instance{}` is reachable
  via both the originating (source) session and the new (target)
  session — replies to inbounds in either chat go through the same
  CCProcess pid but route back to the right `cli:channel/<sid>` topic.

  ## Args

    * `session` (required) — UUID of the target session to attach to.
    * `name` (required) — name of the existing instance to extend.

  When the operator's chat-current session can be resolved (`chat_id`
  + `app_id` injected by the SlashHandler envelope), it is used as the
  SOURCE session for the instance lookup. Without chat-current, the
  source session must be passed via the `session_id=` arg (rare —
  reserved for ops scripting).

  ## Permission

  `session:default/spawn` — same family as `/agent:add` /
  `/agent:remove`. Spec calls this `agent.attach` semantically; the
  flat-cap declaration reuses the existing per-session spawn cap so
  ops don't have to grant a new permission per user.
  """

  use Esr.Commands.Meta

  command :agent_add_session do
    slash         "/agent:add-session"
    category      "Agents"
    description   "把已有 agent 实例绑定到另一个 session（Phase 7 多会话同实例）"
    permission    "session:default/spawn"
    requires_user_binding      true
    requires_workspace_binding false

    arg :session, required: true, doc: "target session UUID to attach the instance to"
    arg :name, required: true, doc: "existing instance name"

    error :no_source_session,
          "no chat-current session and source_session_id= not provided; can't locate instance '%{name}'"
    error :instance_not_found,
          "no agent named '%{name}' in source session '%{source}'"
    error :name_taken_in_target,
          "target session '%{target}' already has a different agent named '%{name}'"
    error :invalid_args,
          "/agent:add-session requires args.session (UUID) and args.name (non-empty string)"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Entity.Agent.InstanceRegistry
  alias Esr.Session.ChatRouting.Registry, as: ChatRouting

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  # Chat-current fallback for the SOURCE session: when operator omits
  # `source_session_id=` but the SlashHandler injected chat_id+app_id,
  # resolve via ChatRouting and recurse with the source filled in.
  def execute(
        %{
          "args" =>
            %{"chat_id" => chat_id, "app_id" => app_id, "session" => target_sid, "name" => name} =
              args
        } = cmd
      )
      when is_binary(chat_id) and chat_id != "" and
             is_binary(app_id) and app_id != "" and
             is_binary(target_sid) and target_sid != "" and
             is_binary(name) and name != "" and
             not is_map_key(args, "source_session_id") do
    case ChatRouting.current_session(chat_id, app_id) do
      {:ok, sid} ->
        execute(put_in(cmd, ["args", "source_session_id"], sid))

      :not_found ->
        Render.error(__MODULE__.command_meta(), :no_source_session, %{name: name})
    end
  end

  def execute(%{
        "args" => %{
          "session" => target_sid,
          "name" => name,
          "source_session_id" => source_sid
        }
      })
      when is_binary(target_sid) and target_sid != "" and
             is_binary(name) and name != "" and
             is_binary(source_sid) and source_sid != "" do
    case InstanceRegistry.attach_to_session(name, source_sid, target_sid) do
      :ok ->
        {:ok,
         %{
           "action" => "attached",
           "name" => name,
           "source_session_id" => source_sid,
           "target_session_id" => target_sid
         }}

      {:error, :not_found} ->
        Render.error(__MODULE__.command_meta(), :instance_not_found, %{
          name: name,
          source: source_sid
        })

      {:error, {:name_taken_in_target, sid}} ->
        Render.error(__MODULE__.command_meta(), :name_taken_in_target, %{
          name: name,
          target: sid
        })
    end
  end

  # Args present (session+name) but no source resolvable. Surface the
  # specific error rather than the generic invalid_args.
  def execute(%{"args" => %{"session" => target_sid, "name" => name}})
      when is_binary(target_sid) and target_sid != "" and
             is_binary(name) and name != "" do
    Render.error(__MODULE__.command_meta(), :no_source_session, %{name: name})
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end
end

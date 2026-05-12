defmodule Esr.Commands.Agent.Rename do
  @moduledoc """
  `/agent:rename` — rename an agent instance within a session. Net-new
  in rev-3 §4.2 (no `/session:rename-agent` predecessor).

  Args: `session_id`, `name`, `new_name` (all required).
  """

  use Esr.Commands.Meta

  command :agent_rename do
    slash         "/agent:rename"
    category      "Agents"
    description   "重命名 agent；name=<旧> new_name=<新>"
    permission    "session:default/spawn"
    requires_user_binding      true
    requires_workspace_binding false

    arg :name,     required: true, doc: "current agent name"
    arg :new_name, required: true, doc: "new agent name"

    error :not_found, "agent '%{name}' not found in session '%{session_id}'"
    error :duplicate_agent_name,
          "agent '%{new_name}' already exists in session '%{session_id}' (pick a different name)"
    error :invalid_args,
          "/agent:rename requires args.session_id, args.name, and args.new_name"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Uri.Compat

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"session_id" => sid, "name" => name, "new_name" => new_name}})
      when is_binary(sid) and sid != "" and
             is_binary(name) and name != "" and
             is_binary(new_name) and new_name != "" do
    case Compat.rename_instance(sid, name, new_name) do
      :ok ->
        {:ok,
         %{
           "action" => "renamed",
           "session_id" => sid,
           "old_name" => name,
           "new_name" => new_name
         }}

      {:error, :not_found} ->
        Render.error(__MODULE__.command_meta(), :not_found, %{name: name, session_id: sid})

      {:error, :duplicate_agent_name} ->
        Render.error(__MODULE__.command_meta(), :duplicate_agent_name, %{
          new_name: new_name,
          session_id: sid
        })
    end
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end
end

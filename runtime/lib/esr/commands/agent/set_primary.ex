defmodule Esr.Commands.Agent.SetPrimary do
  @moduledoc """
  Set the primary agent for a session (`/agent:set-primary`).

  The primary agent receives all plain-text messages that do not contain
  an explicit `@<name>` mention (spec Q8=A).

  Replaces the legacy `Esr.Commands.Session.SetPrimary`; logic identical
  (spec rev-3 §4.2 D1 hard-cutover). The old session/set_primary.ex is
  deleted in Task C.9.
  """

  use Esr.Commands.Meta

  command :agent_set_primary do
    slash         "/agent:set-primary"
    category      "Agents"
    description   "设当前 session 的 primary agent"
    permission    "session:default/spawn"
    requires_user_binding      true
    requires_workspace_binding false

    arg :name, required: true, doc: "agent name to promote to primary"

    error :not_found,    "no agent named '%{name}' in session '%{session_id}'"
    error :invalid_args, "/agent:set-primary requires args.session_id and args.name (non-empty strings)"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Uri.Compat

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"session_id" => sid, "name" => name}})
      when is_binary(sid) and sid != "" and is_binary(name) and name != "" do
    case Compat.set_primary(sid, name) do
      :ok ->
        {:ok,
         %{
           "action" => "primary_set",
           "session_id" => sid,
           "primary_agent" => name
         }}

      {:error, :not_found} ->
        Render.error(__MODULE__.command_meta(), :not_found, %{name: name, session_id: sid})
    end
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end
end

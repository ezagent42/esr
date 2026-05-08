defmodule Esr.Commands.Agent.SetPrimary do
  @moduledoc """
  Set the primary agent for a session (`/agent:set-primary`).

  The primary agent receives all plain-text messages that do not contain
  an explicit `@<name>` mention (spec Q8=A).

  Replaces the legacy `Esr.Commands.Session.SetPrimary`; logic identical
  (spec rev-3 §4.2 D1 hard-cutover). The old session/set_primary.ex is
  deleted in Task C.9.
  """

  @behaviour Esr.Role.Control

  alias Esr.Entity.Agent.InstanceRegistry

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"session_id" => sid, "name" => name}})
      when is_binary(sid) and sid != "" and is_binary(name) and name != "" do
    case InstanceRegistry.set_primary(sid, name) do
      :ok ->
        {:ok,
         %{
           "action" => "primary_set",
           "session_id" => sid,
           "primary_agent" => name
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
       "message" => "/agent:set-primary requires args.session_id and args.name (non-empty strings)"
     }}
  end
end

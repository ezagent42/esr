defmodule Esr.Commands.Agent.Primary do
  @moduledoc """
  `/agent:primary` — read-only: show the primary agent name for the
  chat-current session. Net-new in spec rev-3 §4.2.
  """

  @behaviour Esr.Role.Control

  alias Esr.Session.ChatRouting.Registry, as: ChatRouting

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"chat_id" => chat_id, "app_id" => app_id}})
      when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
    with {:ok, sid} <- ChatRouting.current_session(chat_id, app_id),
         {:ok, name} <- Esr.Entity.Agent.InstanceRegistry.primary(sid) do
      {:ok, %{"session_id" => sid, "primary" => name}}
    else
      :not_found ->
        {:error,
         %{
           "type" => "no_current_session",
           "message" => "no session attached to this chat; /session:bind-chat first"
         }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "/agent:primary requires chat context"
     }}
  end
end

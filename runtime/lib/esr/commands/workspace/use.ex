defmodule Esr.Commands.Workspace.Use do
  @moduledoc """
  `/workspace use` slash — set the default workspace for the current chat.

  Future `/new-session` calls from this `(chat_id, app_id)` slot will
  resolve to this workspace unless overridden at session-creation time.

  ## Args
      args: %{
        "name"    => "esr-dev",         # required, workspace name
        "chat_id" => "oc_xxx",          # injected by chat envelope
        "app_id"  => "cli_xxx"          # injected by chat envelope
      }
  """

  @behaviour Esr.Role.Control

  alias Esr.Resource.Workspace.NameIndex
  alias Esr.Resource.ChatScope.Registry, as: ChatScopeRegistry

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd)

  def execute(%{"args" => %{"name" => name, "chat_id" => chat_id, "app_id" => app_id}})
      when is_binary(name) and name != ""
       and is_binary(chat_id) and chat_id != ""
       and is_binary(app_id) and app_id != "" do
    case lookup_id(name) do
      :not_found ->
        {:error, %{"type" => "unknown_workspace", "name" => name}}

      {:ok, id} ->
        :ok = ChatScopeRegistry.set_default_workspace(chat_id, app_id, id)

        {:ok,
         %{
           "name" => name,
           "id" => id,
           "chat_id" => chat_id,
           "app_id" => app_id,
           "action" => "default_workspace_set"
         }}
    end
  end

  def execute(%{"args" => %{"name" => name}}) when is_binary(name) and name != "" do
    {:error,
     %{
       "type" => "missing_chat_context",
       "message" => "/workspace use must be invoked from a chat (chat_id + app_id required)"
     }}
  end

  def execute(_) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" =>
         "workspace_use requires args.name (and chat_id + app_id from envelope)"
     }}
  end

  defp lookup_id(name), do: NameIndex.id_for_name(:esr_workspace_name_index, name)
end

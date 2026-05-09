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

  use Esr.Commands.Meta

  command :workspace_use do
    slash         "/workspace:use"
    category      "Workspace"
    description   "设当前 chat 的 default workspace（per-chat 偏好；/session:new 解析时使用）"
    permission    "workspace.create"
    requires_user_binding      true
    requires_workspace_binding false

    arg :name, required: true, doc: "workspace 名"

    error :invalid_args,         "workspace_use requires args.name (and chat_id + app_id from envelope)"
    error :missing_chat_context, "/workspace use must be invoked from a chat (chat_id + app_id required)"
    error :unknown_workspace,    "workspace %{name} not found"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Resource.Workspace.NameIndex
  alias Esr.Session.ChatRouting.Registry, as: ChatScopeRegistry

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd)

  def execute(%{"args" => %{"name" => name, "chat_id" => chat_id, "app_id" => app_id}})
      when is_binary(name) and name != ""
       and is_binary(chat_id) and chat_id != ""
       and is_binary(app_id) and app_id != "" do
    case lookup_id(name) do
      :not_found ->
        Render.error(__MODULE__.command_meta(), :unknown_workspace, %{name: name})

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
    Render.error(__MODULE__.command_meta(), :missing_chat_context)
  end

  def execute(_) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end

  defp lookup_id(name), do: NameIndex.id_for_name(:esr_workspace_name_index, name)
end

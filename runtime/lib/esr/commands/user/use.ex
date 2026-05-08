defmodule Esr.Commands.User.Use do
  @moduledoc """
  `/user:use workspace=<name>` — set the submitting user's default
  workspace.

  Symmetric to `/workspace:use` (which sets the chat-default). The
  user-default is the third layer of the `/session:new` workspace
  fallback chain (see `Esr.Commands.Workspace.Resolve`).

  ## Args
      args: %{"workspace" => "esr-dev"}

  ## Result shape
      {:ok,  %{"action" => "user_default_set",
               "username" => "alice", "workspace" => "esr-dev",
               "workspace_id" => "<uuid>"}}
      {:error, %{"type" => "invalid_args" | "unknown_workspace" |
                              "unknown_user", ...}}
  """

  @behaviour Esr.Role.Control

  alias Esr.Entity.User.Registry, as: UserRegistry
  alias Esr.Resource.Workspace.NameIndex, as: WsNameIndex
  alias Esr.Resource.Workspace.Registry, as: WsRegistry

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"workspace" => ws_name}} = cmd)
      when is_binary(ws_name) and ws_name != "" do
    with {:ok, username} <- resolve_submitter(cmd),
         {:ok, ws_id} <- resolve_workspace_id(ws_name),
         :ok <- UserRegistry.set_default_workspace(username, ws_id) do
      {:ok,
       %{
         "action" => "user_default_set",
         "username" => username,
         "workspace" => ws_name,
         "workspace_id" => ws_id
       }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "/user:use requires args.workspace (non-empty string)"
     }}
  end

  defp resolve_submitter(%{"submitter_username" => username})
       when is_binary(username) and username != "",
       do: {:ok, username}

  defp resolve_submitter(%{"submitted_by" => ou_id}) when is_binary(ou_id) and ou_id != "" do
    case UserRegistry.lookup_by_feishu_id(ou_id) do
      {:ok, username} -> {:ok, username}
      :not_found -> {:error, %{"type" => "unknown_user", "message" => "submitter #{ou_id} has no esr-user binding"}}
    end
  end

  defp resolve_submitter(_),
    do: {:error, %{"type" => "unknown_user", "message" => "no submitter context"}}

  defp resolve_workspace_id(ws_name) do
    case WsNameIndex.id_for_name(:esr_workspace_name_index, ws_name) do
      {:ok, ws_id} ->
        case WsRegistry.get_by_id(ws_id) do
          {:ok, _} -> {:ok, ws_id}
          :not_found -> {:error, %{"type" => "unknown_workspace", "workspace" => ws_name}}
        end

      :not_found ->
        {:error, %{"type" => "unknown_workspace", "workspace" => ws_name}}
    end
  rescue
    ArgumentError -> {:error, %{"type" => "unknown_workspace", "workspace" => ws_name}}
  end
end

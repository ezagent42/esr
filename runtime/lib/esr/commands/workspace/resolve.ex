defmodule Esr.Commands.Workspace.Resolve do
  @moduledoc """
  Single workspace-resolution chain shared by `/session:new` and
  `/workspace:add-folder` (M-5).

  Specificity ladder:

      1. explicit args["workspace"]                  ← {:explicit, name}
      2. chat-default via ChatScope.Registry         ← {:chat_default, name}
      3. user-default via User.Registry              ← {:user_default, name}
      4. :no_match                                   ← caller maps to error

  The resolver only returns workspace **names** (not UUIDs); callers
  re-resolve via `Workspace.NameIndex` if they need the UUID — keeps
  the chain pure and testable without a UUID mocking layer.

  Submitter is sourced from `args["submitter_username"]` when present,
  otherwise resolved via `User.Registry.lookup_by_feishu_id/1` from
  `args["submitted_by"]`.
  """

  alias Esr.Entity.User.Registry, as: UserRegistry
  alias Esr.Session.ChatRouting.Registry, as: ChatScope
  alias Esr.Resource.Workspace.NameIndex, as: WsNameIndex
  alias Esr.Resource.Workspace.Registry, as: WsRegistry

  @type tag ::
          {:explicit, String.t()}
          | {:chat_default, String.t()}
          | {:user_default, String.t()}
          | :no_match

  @spec resolve_workspace_for_args(map()) :: tag()
  def resolve_workspace_for_args(args) when is_map(args) do
    cond do
      is_binary(args["workspace"]) and args["workspace"] != "" ->
        {:explicit, args["workspace"]}

      (chat_default_name = lookup_chat_default(args)) != nil ->
        {:chat_default, chat_default_name}

      (user_default_name = lookup_user_default(args)) != nil ->
        {:user_default, user_default_name}

      true ->
        :no_match
    end
  end

  defp lookup_chat_default(args) do
    with chat_id when is_binary(chat_id) and chat_id != "" <- args["chat_id"],
         app_id when is_binary(app_id) and app_id != "" <- args["app_id"],
         {:ok, ws_uuid} <- ChatScope.get_default_workspace(chat_id, app_id),
         {:ok, ws} <- WsRegistry.get_by_id(ws_uuid) do
      ws.name
    else
      _ -> nil
    end
  end

  defp lookup_user_default(args) do
    with {:ok, username} <- resolve_submitter(args),
         {:ok, ws_uuid} <- UserRegistry.get_default_workspace(username),
         {:ok, ws} <- WsRegistry.get_by_id(ws_uuid) do
      ws.name
    else
      _ -> nil
    end
  end

  defp resolve_submitter(%{"submitter_username" => username})
       when is_binary(username) and username != "",
       do: {:ok, username}

  defp resolve_submitter(%{"submitted_by" => ou_id}) when is_binary(ou_id) and ou_id != "" do
    UserRegistry.lookup_by_feishu_id(ou_id)
  end

  defp resolve_submitter(_), do: :not_found

  # Convenience for callers that only need a name and don't care which
  # layer hit — used by /workspace:add-folder.
  @spec workspace_name_for_args(map()) :: {:ok, String.t()} | :no_match
  def workspace_name_for_args(args) do
    case resolve_workspace_for_args(args) do
      {_tag, name} -> {:ok, name}
      :no_match -> :no_match
    end
  end

  # Convenience for callers that need the UUID directly.
  @spec workspace_id_for_args(map()) :: {:ok, String.t()} | :no_match | :workspace_gone
  def workspace_id_for_args(args) do
    with {:ok, name} <- workspace_name_for_args(args),
         {:ok, id} <- WsNameIndex.id_for_name(:esr_workspace_name_index, name) do
      {:ok, id}
    else
      :no_match -> :no_match
      :not_found -> :workspace_gone
    end
  rescue
    ArgumentError -> :no_match
  end
end

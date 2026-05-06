defmodule Esr.Commands.Workspace.UnbindChat do
  @moduledoc """
  `/workspace unbind-chat` slash — remove a chat from a workspace's chats[].

  ## Args

      args: %{
        "name" => "esr-dev",
        "chat_id" => "oc_xxx",
        "app_id" => "cli_xxx"    # optional
      }

  ## Result

      {:ok, %{"name" => name, "id" => uuid, "chats" => remaining, "action" => "removed",
              "removed_count" => n}}
      {:error, %{"type" => ..., ...}}

  ## Matching strategy

  If `args.app_id` is given, match on `(chat_id, app_id)` exactly.
  If `args.app_id` is omitted, match on `chat_id` alone (removes ALL chats
  with that chat_id — `removed_count` reflects how many were removed).
  """

  @behaviour Esr.Role.Control

  alias Esr.Resource.Workspace.{Registry, NameIndex}

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd)

  def execute(%{"args" => %{"name" => name, "chat_id" => chat_id} = args})
      when is_binary(name) and name != "" and is_binary(chat_id) and chat_id != "" do
    app_id = args["app_id"]

    with {:ok, ws} <- lookup_struct_by_name(name) do
      {remaining, removed_count} = filter_chats(ws.chats, chat_id, app_id)

      if removed_count == 0 do
        {:error,
         %{
           "type" => "chat_not_bound",
           "chat_id" => chat_id,
           "name" => name,
           "message" => "chat is not bound to this workspace"
         }}
      else
        updated_ws = %{ws | chats: remaining}

        with :ok <- Registry.put(updated_ws) do
          {:ok,
           %{
             "name" => name,
             "id" => ws.id,
             "chats" => serialise_chats(remaining),
             "action" => "removed",
             "removed_count" => removed_count
           }}
        end
      end
    end
  end

  def execute(_) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "workspace_unbind_chat requires args.name and args.chat_id"
     }}
  end

  ## Internals ---------------------------------------------------------------

  # When app_id is given (non-nil, non-empty), match on (chat_id, app_id) exactly.
  # Otherwise, match on chat_id alone.
  defp filter_chats(chats, chat_id, app_id)
       when is_binary(app_id) and app_id != "" do
    {remaining, removed} =
      Enum.split_with(chats, fn c -> not (c.chat_id == chat_id and c.app_id == app_id) end)

    {remaining, length(removed)}
  end

  defp filter_chats(chats, chat_id, _app_id) do
    {remaining, removed} =
      Enum.split_with(chats, fn c -> c.chat_id != chat_id end)

    {remaining, length(removed)}
  end

  defp lookup_struct_by_name(name) do
    case NameIndex.id_for_name(:esr_workspace_name_index, name) do
      {:ok, id} ->
        case Registry.get_by_id(id) do
          {:ok, ws} -> {:ok, ws}
          :not_found -> workspace_not_found(name)
        end

      :not_found ->
        workspace_not_found(name)
    end
  end

  defp workspace_not_found(name) do
    {:error,
     %{
       "type" => "unknown_workspace",
       "name" => name,
       "message" => "workspace #{inspect(name)} not found"
     }}
  end

  defp serialise_chats(chats) do
    Enum.map(chats, fn c ->
      %{"chat_id" => c.chat_id, "app_id" => c.app_id, "kind" => Map.get(c, :kind, "dm")}
    end)
  end
end

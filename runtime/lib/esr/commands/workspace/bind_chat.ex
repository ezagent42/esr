defmodule Esr.Commands.Workspace.BindChat do
  @moduledoc """
  `/workspace bind-chat` slash — append a chat to a workspace's chats[].

  ## Args

      args: %{
        "name" => "esr-dev",
        "chat_id" => "oc_xxx",
        "app_id" => "cli_xxx",         # required (arg or envelope-injected)
        "kind" => "dm"                  # optional, default "dm"
      }

  ## Result

      {:ok, %{"name" => name, "id" => uuid, "chats" => [...], "action" => "added" | "already_bound"}}
      {:error, %{"type" => ..., ...}}

  ## app_id resolution

  The slash dispatcher injects `app_id` from the envelope when the call comes
  from a chat platform. CLI invocation has no envelope, so the user must pass
  `app_id=<cli_xxx>` explicitly. Both paths write into `args["app_id"]`.

  ## Idempotency

  If `(chat_id, app_id)` already exists in `ws.chats`, returns
  `action="already_bound"` without writing.
  """

  use Esr.Commands.Meta

  command :workspace_bind_chat do
    slash         "/workspace:bind-chat"
    category      "Workspace"
    description   "把 chat 加进 workspace.chats[]；app_id 默认从 envelope 注入"
    permission    "workspace.create"
    requires_user_binding      true
    requires_workspace_binding false

    arg :name,    required: true,  doc: "workspace 名"
    arg :chat_id, required: true,  doc: "chat ID"
    arg :app_id,  required: false, doc: "envelope 自动注入"
    arg :kind,    required: false, default: "dm", doc: "chat 类型"

    error :invalid_args,      "workspace_bind_chat requires args.name and args.chat_id"
    error :missing_app_id,    "bind-chat requires app_id (passed as arg or auto-injected by chat envelope)"
    error :unknown_workspace, "workspace %{name} not found"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Resource.Workspace.{Registry, NameIndex}

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd)

  def execute(%{"args" => %{"name" => name, "chat_id" => chat_id} = args})
      when is_binary(name) and name != "" and is_binary(chat_id) and chat_id != "" do
    app_id = args["app_id"]
    kind = args["kind"] || "dm"

    with :ok <- validate_app_id(app_id),
         {:ok, ws} <- lookup_struct_by_name(name) do
      case already_bound?(ws.chats, chat_id, app_id) do
        true ->
          {:ok,
           %{
             "name" => name,
             "id" => ws.id,
             "chats" => serialise_chats(ws.chats),
             "action" => "already_bound"
           }}

        false ->
          new_chat = %{chat_id: chat_id, app_id: app_id, kind: kind}
          updated_chats = ws.chats ++ [new_chat]
          updated_ws = %{ws | chats: updated_chats}

          with :ok <- Registry.put(updated_ws) do
            {:ok,
             %{
               "name" => name,
               "id" => ws.id,
               "chats" => serialise_chats(updated_chats),
               "action" => "added"
             }}
          end
      end
    end
  end

  def execute(_) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end

  ## Internals ---------------------------------------------------------------

  defp validate_app_id(app_id) when is_binary(app_id) and app_id != "", do: :ok

  defp validate_app_id(_) do
    Render.error(__MODULE__.command_meta(), :missing_app_id)
  end

  defp already_bound?(chats, chat_id, app_id) do
    Enum.any?(chats, fn c -> c.chat_id == chat_id and c.app_id == app_id end)
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
    Render.error(__MODULE__.command_meta(), :unknown_workspace, %{name: name})
  end

  defp serialise_chats(chats) do
    Enum.map(chats, fn c ->
      %{"chat_id" => c.chat_id, "app_id" => c.app_id, "kind" => Map.get(c, :kind, "dm")}
    end)
  end
end

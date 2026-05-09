defmodule Esr.Commands.Session.UnbindChat do
  @moduledoc """
  `/session:unbind-chat` — leave a session in the current chat scope.

  Unbinding keeps the session alive — it just removes the `(chat_id,
  app_id)` mapping. No capability check required: you can always leave
  a session you are attached to.

  ## Args

    * `session` (optional) — UUID of the session to unbind. When
      absent, defaults to the current session for this chat.

  ## Flow

    1. Resolve UUID: from `args["session"]` or
       `ChatScope.Registry.current_session/2`.
    2. If a UUID was provided, validate it looks like a UUID (reject
       names per Phase 5 UUID-only contract).
    3. `ChatScope.Registry.detach_session(chat_id, app_id, uuid)`.
    4. Return `{:ok, %{"session_id" => uuid, "detached" => true,
       "new_current" => new_current | nil}}`.
  """

  use Esr.Commands.Meta

  command :session_unbind_chat do
    slash         "/session:unbind-chat"
    category      "Sessions"
    description   "离开当前 session;session 保持运行;可省略 session= 默认 unbind 当前"
    permission    nil
    requires_user_binding      true
    requires_workspace_binding false

    arg :session, required: false, doc: "session UUID v4 (defaults to current)"

    error :invalid_args,         "/session:unbind-chat requires a chat context (chat_id + app_id in envelope)"
    error :invalid_session_uuid, "session unbind-chat requires a UUID; use /session:list to see available sessions"
    error :no_current_session,   "no session is currently attached to this chat; pass session=<uuid> explicitly"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Session.ChatRouting.Registry, as: ChatScopeRegistry

  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"submitted_by" => _submitter, "args" => args})
      when is_map(args) do
    raw_session = Map.get(args, "session")
    chat_id = Map.get(args, "chat_id", "")
    app_id = Map.get(args, "app_id", "")

    with :ok <- require_chat_context(chat_id, app_id),
         {:ok, uuid} <- resolve_session(raw_session, chat_id, app_id) do
      :ok = ChatScopeRegistry.detach_session(chat_id, app_id, uuid)

      new_current =
        case ChatScopeRegistry.current_session(chat_id, app_id) do
          {:ok, s} -> s
          :not_found -> nil
        end

      {:ok,
       %{
         "session_id" => uuid,
         "detached" => true,
         "new_current" => new_current
       }}
    end
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp require_chat_context(chat_id, app_id)
       when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
    :ok
  end

  defp require_chat_context(_, _) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end

  # Explicit UUID arg supplied
  defp resolve_session(raw, _chat_id, _app_id) when is_binary(raw) and raw != "" do
    if Regex.match?(@uuid_re, raw) do
      {:ok, raw}
    else
      Render.error(__MODULE__.command_meta(), :invalid_session_uuid)
    end
  end

  # No explicit arg — fall back to current session for this chat
  defp resolve_session(_raw, chat_id, app_id) do
    case ChatScopeRegistry.current_session(chat_id, app_id) do
      {:ok, sid} ->
        {:ok, sid}

      :not_found ->
        Render.error(__MODULE__.command_meta(), :no_current_session)
    end
  end
end

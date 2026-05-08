defmodule Esr.Commands.Session.Detach do
  @moduledoc """
  `/session:detach` — leave a session in the current chat scope.

  Detaching keeps the session alive — it just removes the `(chat_id,
  app_id)` mapping. No capability check required: you can always leave
  a session you are attached to.

  ## Args

    * `session` (optional) — UUID of the session to detach. When
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

  @behaviour Esr.Role.Control

  alias Esr.Resource.ChatScope.Registry, as: ChatScopeRegistry

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
    {:error,
     %{
       "type" => "invalid_args",
       "message" =>
         "/session:detach requires a chat context (chat_id + app_id in envelope)"
     }}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp require_chat_context(chat_id, app_id)
       when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
    :ok
  end

  defp require_chat_context(_, _) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "/session:detach requires a chat context (chat_id + app_id in envelope)"
     }}
  end

  # Explicit UUID arg supplied
  defp resolve_session(raw, _chat_id, _app_id) when is_binary(raw) and raw != "" do
    if Regex.match?(@uuid_re, raw) do
      {:ok, raw}
    else
      {:error,
       %{
         "type" => "invalid_session_uuid",
         "message" =>
           "session detach requires a UUID; use /session:list to see available sessions"
       }}
    end
  end

  # No explicit arg — fall back to current session for this chat
  defp resolve_session(_raw, chat_id, app_id) do
    case ChatScopeRegistry.current_session(chat_id, app_id) do
      {:ok, sid} ->
        {:ok, sid}

      :not_found ->
        {:error,
         %{
           "type" => "no_current_session",
           "message" =>
             "no session is currently attached to this chat; pass session=<uuid> explicitly"
         }}
    end
  end
end

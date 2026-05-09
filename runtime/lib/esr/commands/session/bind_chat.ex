defmodule Esr.Commands.Session.BindChat do
  @moduledoc """
  `/session:bind-chat` — bind an existing session to the current chat scope.

  ## Args

    * `session` (required) — session UUID. Name input is rejected per
      Phase 5 spec D2 + D5 (UUID-only contract).

  ## Flow

    1. Validate `session` arg is a valid UUID v4; reject names with a
       descriptive error directing the user to `/session:list`.
    2. `Session.Registry.get_by_id/1` — if `:not_found`, return
       `unknown_session`.
    3. Cap check: `Capability.Grants.has?(submitter,
       "session:<uuid>/attach")` or `"session:<uuid>/admin"` — if
       neither held, return `not_authorized`.
    4. `ChatScope.Registry.attach_session(chat_id, app_id, uuid)`.
    5. Return `{:ok, %{"session_id" => uuid, "attached" => true}}`.
  """

  use Esr.Commands.Meta

  command :session_bind_chat do
    slash         "/session:bind-chat"
    category      "Sessions"
    description   "把已有 session 加入当前 chat;UUID-only(用 /session:list 查 UUID)"
    permission    "session.attach"
    requires_user_binding      true
    requires_workspace_binding false

    arg :session, required: true, doc: "session UUID v4"

    error :invalid_args,         "/session:bind-chat requires args.session (UUID) and a chat context (chat_id + app_id)"
    error :invalid_session_uuid, "session bind-chat requires a UUID; use /session:list to see available sessions"
    error :unknown_session,      "session '%{session}' not found"
    error :not_authorized,       "you do not have 'session:%{session}/attach' or 'session:%{session}/admin'; ask the session owner to run /session:share"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Resource.Session.Registry, as: SessionRegistry
  alias Esr.Session.ChatRouting.Registry, as: ChatScopeRegistry
  alias Esr.Resource.Capability.Grants

  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"submitted_by" => submitter, "args" => args})
      when is_binary(submitter) and is_map(args) do
    raw_session = Map.get(args, "session", "")
    chat_id = Map.get(args, "chat_id", "")
    app_id = Map.get(args, "app_id", "")

    with :ok <- validate_uuid(raw_session),
         {:ok, _session} <- fetch_session(raw_session),
         :ok <- check_cap(submitter, raw_session),
         :ok <- require_chat_context(chat_id, app_id),
         :ok <- ChatScopeRegistry.attach_session(chat_id, app_id, raw_session) do
      {:ok,
       %{
         "session_id" => raw_session,
         "attached" => true
       }}
    end
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_uuid(s) when is_binary(s) and s != "" do
    if Regex.match?(@uuid_re, s) do
      :ok
    else
      Render.error(__MODULE__.command_meta(), :invalid_session_uuid)
    end
  end

  defp validate_uuid(_) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end

  defp fetch_session(uuid) do
    case SessionRegistry.get_by_id(uuid) do
      {:ok, _s} = ok ->
        ok

      :not_found ->
        Render.error(__MODULE__.command_meta(), :unknown_session, %{session: uuid})
    end
  end

  defp check_cap(submitter, uuid) do
    attach_cap = "session:#{uuid}/attach"
    admin_cap = "session:#{uuid}/admin"

    if Grants.has?(submitter, attach_cap) or Grants.has?(submitter, admin_cap) do
      :ok
    else
      Render.error(__MODULE__.command_meta(), :not_authorized, %{session: uuid})
    end
  end

  defp require_chat_context(chat_id, app_id)
       when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
    :ok
  end

  defp require_chat_context(_, _) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end
end

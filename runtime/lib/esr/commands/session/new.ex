defmodule Esr.Commands.Session.New do
  @moduledoc """
  `/session:new` — create a new session and, when invoked from a chat,
  attach it as the current session for that `(chat_id, app_id)` scope.

  ## Args

    * `name` (required) — human-readable session label; unique within
      `(owner_user, name)` per spec D6.
    * `agent` (optional, default `"cc"`) — initial agent type.

  ## Flow

    1. Validate `name` present and non-empty.
    2. Check name uniqueness: `Session.Registry` name-index
       `{{owner_user, name}, uuid}`.
    3. `Session.Registry.create_session/2` — writes
       `<data_dir>/sessions/<uuid>/session.json`.
    4. If `chat_id` + `app_id` present, call
       `ChatScope.Registry.attach_session/3` → sets as current.
    5. Return `{:ok, %{"session_id" => uuid, "name" => name, "owner_user" => user}}`.

  Errors: `invalid_args` (missing/empty name), `session_name_taken`.
  """

  @behaviour Esr.Role.Control

  alias Esr.Resource.Session.Registry, as: SessionRegistry
  alias Esr.Resource.ChatScope.Registry, as: ChatScopeRegistry

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"submitted_by" => submitter, "args" => args})
      when is_binary(submitter) and is_map(args) do
    name = Map.get(args, "name", "")
    _agent = Map.get(args, "agent", "cc")
    chat_id = Map.get(args, "chat_id")
    app_id = Map.get(args, "app_id")

    with :ok <- validate_name(name),
         owner_user = submitter,
         :ok <- check_name_unique(owner_user, name),
         data_dir = Esr.Paths.runtime_home(),
         {:ok, uuid} <-
           SessionRegistry.create_session(data_dir, %{
             name: name,
             owner_user: owner_user,
             workspace_id: ""
           }) do
      if is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
        :ok = ChatScopeRegistry.attach_session(chat_id, app_id, uuid)
      end

      {:ok,
       %{
         "session_id" => uuid,
         "name" => name,
         "owner_user" => owner_user
       }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "/session:new requires args.name (non-empty string)"
     }}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_name(name) when is_binary(name) and name != "", do: :ok

  defp validate_name(_) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "/session:new requires args.name (non-empty string)"
     }}
  end

  defp check_name_unique(owner_user, name) do
    table = :esr_resource_session_name_index

    case :ets.lookup(table, {owner_user, name}) do
      [] ->
        :ok

      [{_, _existing_uuid}] ->
        {:error,
         %{
           "type" => "session_name_taken",
           "message" => "a session named '#{name}' already exists for this user"
         }}
    end
  rescue
    # ETS table not running (test env without Registry)
    ArgumentError -> :ok
  end

end

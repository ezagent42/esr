defmodule Esr.Commands.Session.Share do
  @moduledoc """
  `/session:share` — grant another user access to a session.

  Sugar for `/cap:grant`. Internally calls `Esr.Commands.Cap.Grant.execute/1`
  after building the canonical cap string.

  ## Args

    * `session` (required) — session UUID (UUID-only, Phase 5 D2 + D5).
    * `user` (required) — target username.
    * `perm` (optional, default `"attach"`) — `"attach"` or `"admin"`.

  ## Flow

    1. Validate `session` is a UUID v4.
    2. Resolve `user` username → UUID via
       `Esr.Entity.User.NameIndex.id_for_name/2`.
    3. Map `perm` → cap string:
         `"attach"` → `"session:<uuid>/attach"`
         `"admin"`  → `"session:<uuid>/admin"`
    4. Delegate to `Esr.Commands.Cap.Grant.execute/1` with
       `%{"args" => %{"principal_id" => user_uuid, "permission" => cap}}`.
    5. Return `{:ok, %{"session_id" => uuid, "granted_to" => username, "perm" => perm}}`.
  """

  @behaviour Esr.Role.Control

  alias Esr.Entity.User.NameIndex
  alias Esr.Commands.Cap.Grant

  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  @valid_perms ~w(attach admin)

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"submitted_by" => _submitter, "args" => args})
      when is_map(args) do
    raw_session = Map.get(args, "session", "")
    username = Map.get(args, "user", "")
    perm = Map.get(args, "perm", "attach")

    with :ok <- validate_session_uuid(raw_session),
         :ok <- validate_perm(perm),
         :ok <- validate_user(username),
         {:ok, user_uuid} <- lookup_user(username),
         cap = build_cap(raw_session, perm),
         {:ok, _grant_result} <-
           Grant.execute(%{
             "args" => %{"principal_id" => user_uuid, "permission" => cap}
           }) do
      {:ok,
       %{
         "session_id" => raw_session,
         "granted_to" => username,
         "perm" => perm
       }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" =>
         "/session:share requires args.session (UUID), args.user (username), and optional args.perm (attach|admin)"
     }}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_session_uuid(s) when is_binary(s) and s != "" do
    if Regex.match?(@uuid_re, s) do
      :ok
    else
      {:error,
       %{
         "type" => "invalid_session_uuid",
         "message" =>
           "session share requires a UUID; use /session:list to see available sessions"
       }}
    end
  end

  defp validate_session_uuid(_) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "/session:share requires args.session (non-empty UUID string)"
     }}
  end

  defp validate_user(username) when is_binary(username) and username != "", do: :ok

  defp validate_user(_) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "/session:share requires args.user (non-empty username)"
     }}
  end

  defp validate_perm(p) when p in @valid_perms, do: :ok

  defp validate_perm(p) do
    {:error,
     %{
       "type" => "invalid_perm",
       "message" =>
         "invalid perm '#{p}'; valid values are: #{Enum.join(@valid_perms, ", ")}"
     }}
  end

  defp lookup_user(username) do
    case NameIndex.id_for_name(username) do
      {:ok, uuid} ->
        {:ok, uuid}

      :not_found ->
        {:error,
         %{
           "type" => "user_not_found",
           "message" => "no user with username '#{username}' is registered"
         }}
    end
  end

  defp build_cap(session_uuid, perm), do: "session:#{session_uuid}/#{perm}"
end

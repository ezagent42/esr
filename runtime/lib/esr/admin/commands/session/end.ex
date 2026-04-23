defmodule Esr.Admin.Commands.Session.End do
  @moduledoc """
  `Esr.Admin.Commands.Session.End` — the consolidated agent-session
  teardown admin command (PR-3 P3-9.2; dispatcher kind `session_end`).

  Given a `session_id` (ULID string) on `args`, delegates to
  `Esr.SessionRouter.end_session/1`, which tears down the
  `Esr.SessionProcess` supervisor subtree (terminating the
  `SessionsSupervisor` child) and unregisters the session from
  `Esr.SessionRegistry`. The router already performs the Registry
  lookup and surfaces `{:error, :unknown_session}` when the session
  id is not live; we pass that through to the caller as a
  `unknown_session`-typed error map.

  Before PR-3 this module name held the legacy branch-worktree
  teardown; that logic now lives in `Esr.Admin.Commands.Session.BranchEnd`
  under dispatcher kind `session_branch_end`.

  ## Result

    * `{:ok, %{"session_id" => sid, "ended" => true}}` — Session
      supervisor torn down and the Registry entry released.
    * `{:error, %{"type" => "unknown_session", "session_id" => sid}}`
      — no live Session for that id (already ended, or never existed).
    * `{:error, %{"type" => "end_failed", "details" => ...}}` —
      unexpected router error; the router keeps running per Risk-E.
    * `{:error, %{"type" => "invalid_args", "message" => ...}}` —
      missing or empty `session_id`, or a malformed command map.
  """

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"session_id" => sid}}) when is_binary(sid) and sid != "" do
    case Esr.SessionRouter.end_session(sid) do
      :ok ->
        {:ok, %{"session_id" => sid, "ended" => true}}

      {:error, :unknown_session} ->
        {:error, %{"type" => "unknown_session", "session_id" => sid}}

      {:error, reason} ->
        {:error, %{"type" => "end_failed", "details" => inspect(reason)}}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "session_end requires args.session_id (non-empty string)"
     }}
  end
end

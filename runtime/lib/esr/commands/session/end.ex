defmodule Esr.Commands.Session.End do
  @moduledoc """
  `Esr.Commands.Session.End` — the consolidated agent-session
  teardown admin command (PR-3 P3-9.2; dispatcher kind `session_end`).

  ## PR-21g / PR-22 resolution path

  Two arg shapes accepted:

  - **Legacy `session_id`** — direct ULID lookup via `Scope.Router.end_session/1`.
    Used by tests and the file-queue admin path.
  - **New `name`** (PR-21d slash grammar) — resolves to session_id via
    `Esr.Uri.Compat.session_uuid_in_scope/4` using
    `(env, username, workspace, name)`. `env` defaults to
    `$ESR_INSTANCE`; `username` and `workspace` come from the args
    (threaded by `SlashHandler`).

  When the args carry `cwd` AND `root` (PR-22: both per-session, both
  threaded by SlashHandler from /end-session), `Esr.Worktree.remove/3`
  is called after the router teardown — but only when the worktree is
  clean (D12 default "prune iff clean"). Dirty worktrees are kept on
  disk + a warning is logged.

  Two-step interactive confirm via `EsrWeb.PendingActionsGuard` is staged
  (PR-21e/f) but not wired here — for now `/end-session` is direct.

  ## Result

    * `{:ok, %{"session_id" => sid, "ended" => true}}` — Session
      supervisor torn down and the Registry entry released.
    * `{:ok, %{..., "worktree_removed" => true | false}}` — PR-21g
      shape; `true` only when a worktree was both registered and
      successfully removed.
    * `{:error, %{"type" => "unknown_session", ...}}`
    * `{:error, %{"type" => "end_failed", ...}}`
    * `{:error, %{"type" => "invalid_args", ...}}`
  """

  use Esr.Commands.Meta

  command :session_end do
    slash         "/session:end"
    category      "Sessions"
    description   "销毁 session;session_id=<uuid> 或 name=<n>"
    permission    "session:default/end"
    requires_user_binding      true
    requires_workspace_binding false

    arg :session_id, required: false, doc: "session ULID/UUID (legacy direct lookup)"
    arg :name,       required: false, doc: "session name (resolved via NameIndex)"

    error :invalid_args,           "session_end %{detail}"
    error :unknown_session,        "session %{session_id} not found"
    error :end_failed,             "session end failed: %{details}"
  end

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  alias Esr.Commands.Render

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"session_id" => sid}} = cmd)
      when is_binary(sid) and sid != "" do
    end_by_session_id(sid, cmd["args"])
  end

  # PR-21g: resolve by URI tuple. `username` + `workspace` come from
  # args (threaded by SlashHandler from envelope.user / params); `env`
  # falls back to $ESR_INSTANCE when not given.
  def execute(%{"args" => %{"name" => name} = args}) when is_binary(name) and name != "" do
    env = args["env"] || Esr.Paths.current_instance()
    username = args["username"] || ""
    workspace = args["workspace"] || ""

    cond do
      username == "" ->
        Render.error(__MODULE__.command_meta(), :invalid_args, %{
          detail: "by name requires args.username"
        })

      workspace == "" ->
        Render.error(__MODULE__.command_meta(), :invalid_args, %{
          detail: "by name requires args.workspace"
        })

      true ->
        case Esr.Uri.Compat.session_uuid_in_scope(env, username, workspace, name) do
          {:ok, sid} ->
            end_by_session_id(sid, args)

          :not_found ->
            Render.error(__MODULE__.command_meta(), :unknown_session, %{session_id: name})
        end
    end
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args, %{
      detail: "requires args.session_id OR args.name (with username + workspace)"
    })
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp end_by_session_id(sid, args) do
    cwd = args["cwd"]
    # PR-22: root is per-session now (was workspace-level pre PR-22).
    # /end-session arrives via slash with the session's URI tuple; the
    # router can't trivially look up the per-session root post-teardown,
    # so we accept args["root"] from the slash threading. Operators who
    # invoke /end-session without root= miss the worktree-prune step
    # (we just log "skipped" and let them clean up via `git worktree
    # remove --force` manually).
    session_root = args["root"]

    case Esr.Session.Router.end_session(sid) do
      :ok ->
        safe_unbind_session(sid)
        maybe_cleanup_transient_workspace(sid, args)
        worktree_removed = maybe_remove_worktree(session_root, cwd)

        {:ok,
         %{
           "session_id" => sid,
           "ended" => true,
           "worktree_removed" => worktree_removed
         }}

      {:error, :unknown_session} ->
        Render.error(__MODULE__.command_meta(), :unknown_session, %{session_id: sid})

      {:error, reason} ->
        Render.error(__MODULE__.command_meta(), :end_failed, %{details: inspect(reason)})
    end
  end

  # Safe wrapper: no-op when SessionBindings GenServer is not running
  # (tests that don't boot the workspace subsystem).
  defp safe_unbind_session(sid) do
    case Process.whereis(Esr.Resource.Workspace.SessionBindings) do
      nil -> :ok
      _pid -> Esr.Resource.Workspace.SessionBindings.unbind_session(sid)
    end
  end

  # Transient workspace cleanup — called after router teardown + unbind.
  # Silent no-op when SessionBindings isn't running (tests that don't
  # boot the workspace subsystem).
  defp maybe_cleanup_transient_workspace(_sid, args) do
    case lookup_workspace_id(args["workspace"]) do
      {:ok, ws_id} ->
        case safe_delete_if_no_sessions(ws_id) do
          {:ok, :deleted} ->
            require Logger

            Logger.info(
              "session_end: transient workspace #{args["workspace"]} (#{ws_id}) deleted (last session ended)"
            )

            :ok

          _ ->
            :ok
        end

      :not_found ->
        :ok

      :unavailable ->
        :ok
    end
  end

  defp safe_delete_if_no_sessions(ws_id) do
    case Process.whereis(Esr.Resource.Workspace.SessionBindings) do
      nil -> {:error, :unavailable}
      _pid -> Esr.Resource.Workspace.SessionBindings.delete_if_no_sessions(ws_id)
    end
  end

  defp lookup_workspace_id(name) when is_binary(name) and name != "" do
    case Esr.Uri.Compat.uuid_for_workspace_name(name) do
      {:ok, id} -> {:ok, id}
      :not_found -> :not_found
    end
  rescue
    ArgumentError -> :unavailable
  end

  defp lookup_workspace_id(_), do: :not_found

  # PR-21g: D12 default — prune iff clean. Dirty worktrees are kept
  # on disk + a warning is logged; operator can prune manually with
  # `git worktree remove --force` once they've reviewed the diff.
  defp maybe_remove_worktree(nil, _cwd), do: false
  defp maybe_remove_worktree(_root, nil), do: false
  defp maybe_remove_worktree(_root, ""), do: false

  defp maybe_remove_worktree(root, cwd) do
    case Esr.Worktree.status(cwd) do
      {:ok, :clean} ->
        case Esr.Worktree.remove(root, cwd, force: false) do
          :ok ->
            true

          {:error, reason} ->
            require Logger
            Logger.warning(
              "session_end: worktree remove failed cwd=#{cwd} reason=#{inspect(reason)}"
            )

            false
        end

      {:ok, :dirty} ->
        require Logger
        Logger.warning(
          "session_end: worktree #{cwd} has uncommitted changes — kept on disk. " <>
            "Remove manually with `git worktree remove --force` once you've reviewed the diff."
        )

        false

      {:error, reason} ->
        require Logger
        Logger.warning(
          "session_end: worktree status check failed cwd=#{cwd} reason=#{inspect(reason)}"
        )

        false
    end
  end
end

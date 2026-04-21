defmodule Esr.Admin.Commands.Session.End do
  @moduledoc """
  `Esr.Admin.Commands.Session.End` — tears down the ephemeral esrd +
  worktree for a branch and cleans up routing/branches state
  (dev-prod-isolation spec §6.4 Session.End bullet + §6.9 + §7.5).

  Called by `Esr.Admin.Dispatcher` inside `Task.start` when a
  `session_end`-kind command reaches the front of the queue.

  ## DI-11 — two paths

  The command honours `args.force` (boolean, default `false`):

    * `force: true` — legacy DI-10 behaviour: shells
      `esr-branch.sh end <branch> --force` immediately, prunes yaml,
      returns `{:ok, %{"branch" => ...}}`.
    * `force: false` (new) — coordinates with the target CC session
      first via the `session.signal_cleanup` MCP tool handshake:

        1. Register `self/0` with `Esr.Admin.Dispatcher` as the waiter
           for `session_id = "<submitter>-<branch>"` (same convention
           as `routing.yaml`'s `cc_session_id`).
        2. Dispatch a cleanup-check request to CC (via `:sender_fn`
           opt; see **CC-side stub** below).
        3. `receive` a `{:cleanup_signal, status, details}` forwarded
           by Dispatcher's `handle_info/2` clause; timeout after
           `opts[:cleanup_timeout_ms]` (default 30_000).

      Outcomes:

        * `status == "CLEANED"` — proceed with the shell `end` (no
          `--force`), prune yaml, `{:ok, ...}` like the force path.
        * `status in ~w[DIRTY UNPUSHED STASHED]` — return
          `{:error, %{"type" => "worktree_<lower>", "details" => ...}}`;
          nothing is torn down.
        * timeout — return `{:error, %{"type" => "cleanup_timeout", ...}}`
          with a hint suggesting `--force` or retry; routing/branches
          state is left untouched.

  ## CC-side stub (DI-11 gap)

  The actual CC inspection tool (`git status / log / stash` via the
  CC MCP server) is out of scope for spec §6.9 in DI-11 — what exists
  today is only the ESR-side receiver (`session.signal_cleanup`). The
  default `:sender_fn` therefore emits a `:telemetry` event and logs,
  but does **not** actually reach a CC session. Tests inject a stub
  `:sender_fn` and directly poke the Dispatcher with a signal to
  simulate CC's response. Wiring the real CC-side `cleanup_check`
  tool is tracked as a v2 gap (see `PHASE7_GAP.md` / spec §13).

  ## Flow (non-force path)

    1. Read `branches.yaml`. If the branch isn't registered → return
       `{:error, %{"type" => "no_such_branch"}}`.
    2. Register with Dispatcher → send cleanup request → block on
       `receive`.
    3. On `CLEANED` → shell `esr-branch.sh end <branch>` (no `--force`).
    4. On `DIRTY | UNPUSHED | STASHED` → return worktree error.
    5. On timeout → return `cleanup_timeout` error.

  ## Result

    * `{:ok, %{"branch" => name}}` — success (both paths).
    * `{:error, %{"type" => "invalid_args"}}` — malformed command.
    * `{:error, %{"type" => "no_such_branch"}}` — branch not in
      branches.yaml.
    * `{:error, %{"type" => "worktree_dirty" | "worktree_unpushed"
      | "worktree_stashed", "details" => ...}}` — CC signal not
      CLEANED; nothing torn down.
    * `{:error, %{"type" => "cleanup_timeout", "hint" => ...}}` —
      no signal within `cleanup_timeout_ms`.
    * `{:error, %{"type" => "branch_end_failed", "details" => msg}}` —
      script failed or JSON was unparseable.

  ## Test injection

    * `:spawn_fn` — 1-arity `{argv} -> {stdout, exit}` stub for
      `System.cmd/3` (same pattern as `Session.New` /
      `RegisterAdapter`).
    * `:cleanup_timeout_ms` — override the 30_000 ms `receive`
      timeout so tests can exercise the timeout branch in under a
      second.
    * `:sender_fn` — 2-arity `(session_id, worktree_path) -> :ok`
      stub standing in for the (stubbed) CC-side cleanup_check
      dispatch. Defaults to a `:telemetry.execute/3` + log-only impl.
  """

  @type result :: {:ok, map()} | {:error, map()}

  require Logger

  @default_cleanup_timeout_ms 30_000
  @worktree_error_statuses ~w[DIRTY UNPUSHED STASHED]

  @spec execute(map()) :: result()
  def execute(cmd), do: execute(cmd, [])

  @spec execute(map(), keyword()) :: result()
  def execute(
        %{"submitted_by" => submitter, "args" => %{"branch" => branch} = args},
        opts
      )
      when is_binary(submitter) and is_binary(branch) and branch != "" do
    case branch_registered?(branch) do
      false ->
        {:error, %{"type" => "no_such_branch"}}

      true ->
        force? = truthy?(Map.get(args, "force", false))

        if force? do
          run_shell_and_persist(branch, submitter, _force? = true, opts)
        else
          run_cleanup_handshake(branch, submitter, opts)
        end
    end
  end

  def execute(_cmd, _opts) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "session_end requires submitted_by and args.branch (non-empty string)"
     }}
  end

  # ------------------------------------------------------------------
  # Non-force (DI-11) path: register → send cleanup-check → receive
  # ------------------------------------------------------------------

  defp run_cleanup_handshake(branch, submitter, opts) do
    session_id = submitter <> "-" <> branch
    timeout_ms = Keyword.get(opts, :cleanup_timeout_ms, @default_cleanup_timeout_ms)
    worktree_path = lookup_worktree_path(branch)

    sender_fn =
      Keyword.get(opts, :sender_fn, fn sid, wpath ->
        default_cleanup_sender(sid, wpath)
      end)

    :ok = Esr.Admin.Dispatcher.register_cleanup(session_id, self())

    try do
      _ = sender_fn.(session_id, worktree_path)

      receive do
        {:cleanup_signal, "CLEANED", _details} ->
          run_shell_and_persist(branch, submitter, _force? = false, opts)

        {:cleanup_signal, status, details} when status in @worktree_error_statuses ->
          {:error,
           %{
             "type" => "worktree_" <> String.downcase(status),
             "details" => details || %{},
             "branch" => branch
           }}

        {:cleanup_signal, status, details} ->
          # CC returned something we don't recognise — surface it as
          # a generic worktree_unknown so the user still sees the raw
          # status rather than waiting out the timeout.
          {:error,
           %{
             "type" => "worktree_unknown",
             "status" => status,
             "details" => details || %{},
             "branch" => branch
           }}
      after
        timeout_ms ->
          {:error,
           %{
             "type" => "cleanup_timeout",
             "branch" => branch,
             "timeout_ms" => timeout_ms,
             "hint" =>
               "CC session did not respond to cleanup_check within " <>
                 "#{timeout_ms}ms. Retry, or re-send /end-session with --force " <>
                 "to skip the check and tear the worktree down regardless."
           }}
      end
    after
      # Deregister whether we got a signal, a timeout, or a crash — no
      # stale session_id → pid entries in the Dispatcher.
      :ok = Esr.Admin.Dispatcher.deregister_cleanup(session_id)
    end
  end

  # The default sender_fn. Today there's no CC-side `cleanup_check`
  # tool the ESR can invoke — spec §6.9 only defines the reverse
  # direction (CC → ESR via `session.signal_cleanup`). We therefore
  # log + emit a telemetry event and rely on the CC operator (or a
  # future CC-side tool) to eventually send the signal back. The
  # `cleanup_timeout` branch is the working fallback for this gap.
  defp default_cleanup_sender(session_id, worktree_path) do
    Logger.info(
      "admin.session_end: cleanup_check STUB — no CC-side tool wired yet " <>
        "(session_id=#{session_id} worktree=#{worktree_path || "?"})"
    )

    :telemetry.execute(
      [:esr, :admin, :session_end_cleanup_check_requested],
      %{count: 1},
      %{session_id: session_id, worktree_path: worktree_path}
    )

    :ok
  end

  defp lookup_worktree_path(branch) do
    case YamlElixir.read_from_file(branches_yaml_path()) do
      {:ok, %{"branches" => %{} = branches}} ->
        case Map.get(branches, branch) do
          %{"worktree_path" => path} when is_binary(path) -> path
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # ------------------------------------------------------------------
  # Shell invocation + yaml persist
  # ------------------------------------------------------------------

  defp run_shell_and_persist(branch, submitter, force?, opts) do
    case call_script(branch, force?, opts) do
      {:ok, _} ->
        with :ok <- remove_from_branches_yaml(branch),
             :ok <- drop_target_from_routing_yaml(branch, submitter) do
          {:ok, %{"branch" => branch}}
        else
          {:error, reason} ->
            {:error,
             %{
               "type" => "branch_end_failed",
               "details" => "yaml persist failed: " <> inspect(reason)
             }}
        end

      {:error, _} = err ->
        err
    end
  end

  defp call_script(branch, force?, opts) do
    argv =
      if force?, do: ["end", branch, "--force"], else: ["end", branch]

    spawn_fn =
      Keyword.get(opts, :spawn_fn, fn {a} ->
        System.cmd(script_path(), a, stderr_to_stdout: true)
      end)

    {output, exit_status} = spawn_fn.({argv})

    case Jason.decode(output) do
      {:ok, %{"ok" => true} = m} when exit_status == 0 ->
        {:ok, m}

      {:ok, %{"ok" => false, "error" => msg}} ->
        {:error, %{"type" => "branch_end_failed", "details" => to_string(msg)}}

      {:ok, other} ->
        {:error,
         %{
           "type" => "branch_end_failed",
           "details" => "unexpected script payload: " <> inspect(other)
         }}

      {:error, %Jason.DecodeError{} = err} ->
        {:error,
         %{
           "type" => "branch_end_failed",
           "details" => "malformed JSON stdout: " <> Exception.message(err)
         }}
    end
  end

  defp script_path do
    repo_root =
      :esr
      |> Application.app_dir()
      |> Path.join("../../../..")
      |> Path.expand()

    Path.join([repo_root, "scripts", "esr-branch.sh"])
  end

  # ------------------------------------------------------------------
  # branches.yaml gate
  # ------------------------------------------------------------------

  defp branch_registered?(branch) do
    case YamlElixir.read_from_file(branches_yaml_path()) do
      {:ok, %{"branches" => %{} = branches}} -> Map.has_key?(branches, branch)
      _ -> false
    end
  end

  # ------------------------------------------------------------------
  # YAML cleanup
  # ------------------------------------------------------------------

  defp remove_from_branches_yaml(branch) do
    path = branches_yaml_path()

    current =
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = m} -> m
        _ -> %{"branches" => %{}}
      end

    branches = Map.get(current, "branches") || %{}
    updated = Map.put(current, "branches", Map.delete(branches, branch))
    Esr.Yaml.Writer.write(path, updated)
  end

  # Drops targets[branch] from every principal, and adjusts
  # principals[submitter].active when it pointed at the removed branch:
  # falls back to the first remaining target name (alphabetically) or
  # unsets when none remain.
  defp drop_target_from_routing_yaml(branch, submitter) do
    path = routing_yaml_path()

    current =
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = m} -> m
        _ -> nil
      end

    case current do
      nil ->
        # Nothing to clean — routing file never existed.
        :ok

      current ->
        principals = Map.get(current, "principals") || %{}

        updated_principals =
          for {pid, principal} <- principals, into: %{} do
            {pid, prune_principal(principal, branch, pid == submitter)}
          end

        Esr.Yaml.Writer.write(path, Map.put(current, "principals", updated_principals))
    end
  end

  # Remove targets[branch]; if this principal is the submitter and their
  # active pointed at the ended branch, fall back to the first remaining
  # target name alphabetically (or nil when empty).
  defp prune_principal(principal, branch, is_submitter?) do
    targets = Map.get(principal, "targets") || %{}
    new_targets = Map.delete(targets, branch)
    principal_with_targets = Map.put(principal, "targets", new_targets)

    if is_submitter? and Map.get(principal, "active") == branch do
      fallback =
        new_targets
        |> Map.keys()
        |> Enum.sort()
        |> List.first()

      Map.put(principal_with_targets, "active", fallback)
    else
      principal_with_targets
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # Accept the classic Elixir booleans + the stringy `"true"` /
  # `"false"` shapes the Feishu slash parser and CLI query strings
  # produce. Anything else → false.
  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp branches_yaml_path, do: Path.join(Esr.Paths.runtime_home(), "branches.yaml")
  defp routing_yaml_path, do: Path.join(Esr.Paths.runtime_home(), "routing.yaml")
end

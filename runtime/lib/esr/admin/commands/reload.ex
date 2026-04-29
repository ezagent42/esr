defmodule Esr.Admin.Commands.Reload do
  @moduledoc """
  `Esr.Admin.Commands.Reload` — kickstarts the launchd-supervised esrd
  process so the runtime picks up freshly-merged code
  (dev-prod-isolation spec §6.4 Reload bullet, plan DI-12 Task 26).

  Called by `Esr.Admin.Dispatcher` inside a `Task.start` when a
  `reload`-kind command reaches the front of the queue. Pure function
  module (no GenServer) so it can be spawned and discarded.

  ## Flow

    1. Resolve the launchctl **label** from `Esr.Paths.esrd_home/0`:
         * `.../.esrd`     → `com.ezagent.esrd`
         * `.../.esrd-dev` → `com.ezagent.esrd-dev`
         * anything else (e.g. `/tmp/esrd-<branch>/`) → `{:error,
           %{"type" => "cannot_determine_label"}}`. This safeguards
           ephemeral per-branch esrds from reloading themselves via
           launchctl (they are NOT launchd-supervised).
    2. Read `<runtime_home>/last_reload.yaml` for the previous
       `last_reload_sha`. If the file is missing (first run) scan range
       is `HEAD..HEAD` — an empty set — so no breaking commits can be
       flagged on first adoption.
    3. Shell `git log <last_sha>..HEAD --grep='^[^:]*!:' \\
       --grep='^BREAKING CHANGE:' --format='%h %s'` — the `--grep`
       pattern matches Conventional Commits' `type(scope)!:` breaking
       marker AND stand-alone `BREAKING CHANGE:` footers.
    4. If the scan returns any lines AND `args.acknowledge_breaking`
       is not `true` → return
       `{:error, %{"type" => "unacknowledged_breaking", "commits" =>
       [...]}}`. Operator re-runs with the flag after reviewing.
    5. Otherwise: spawn `launchctl kickstart -k gui/<uid>/<label>` via
       `Task.start` (fire-and-forget; launchctl returns before the
       restart completes), update `<runtime_home>/last_reload.yaml`
       with the new sha + timestamp + submitter + acknowledged sha
       shorts, and return `{:ok, %{"reloaded" => true, "new_sha" =>
       sha}}`.

  ## Test injection

  `execute/2` accepts opts:

    * `:git_fn`      — `fn argv -> {stdout, exit} end` replacing
      `System.cmd("git", argv, cd: repo_dir)`.
    * `:spawn_fn`    — `fn argv -> {stdout, exit} end` replacing
      `System.cmd("launchctl", argv)`. Same shape as `:git_fn` for
      symmetry; used by tests to assert the launchctl argv without
      mutating the live launchd plist.
    * `:now_iso8601` — override `DateTime.utc_now/0 |> DateTime.to_iso8601/1`
      for deterministic `last_reload_ts` assertions.

  The Dispatcher always calls `execute/1`, which delegates to
  `execute/2` with the real `System.cmd/3`.

  ## Edge cases flagged for follow-up

    * **Concurrent reload** — two operators submitting `reload` back
      to back will each fire a `launchctl kickstart -k` and race to
      write `last_reload.yaml`. The Dispatcher serializes command
      dequeue (one cast at a time) but `Task.start` detaches the
      launchctl call, so overlap is still possible. Mitigation
      deferred until a second operator actually shows up — the
      `launchctl kickstart -k` is idempotent (re-exec the process).
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @spec execute(map()) :: result()
  def execute(cmd), do: execute(cmd, [])

  @spec execute(map(), keyword()) :: result()
  def execute(%{"submitted_by" => submitter} = cmd, opts) when is_binary(submitter) do
    args = Map.get(cmd, "args") || %{}

    with {:ok, label} <- resolve_label(),
         {:ok, head_sha} <- resolve_head_sha(opts),
         {:ok, last_sha} <- read_last_sha(),
         {:ok, breaking} <- scan_breaking_commits(last_sha, opts) do
      ack = args["acknowledge_breaking"] == true

      cond do
        breaking != [] and not ack ->
          {:error, %{"type" => "unacknowledged_breaking", "commits" => breaking}}

        true ->
          kickstart(label, opts)

          ack_shas = if ack, do: Enum.map(breaking, &short_sha/1), else: []

          case write_last_reload(head_sha, submitter, ack_shas, opts) do
            :ok ->
              {:ok, %{"reloaded" => true, "new_sha" => head_sha}}

            {:error, reason} ->
              {:error, %{"type" => "write_last_reload_failed", "detail" => inspect(reason)}}
          end
      end
    end
  end

  def execute(_cmd, _opts) do
    {:error, %{"type" => "invalid_args", "message" => "reload requires submitted_by"}}
  end

  # ------------------------------------------------------------------
  # Label resolution
  # ------------------------------------------------------------------

  # Derive the launchd label from the esrd_home path suffix. Unknown
  # suffix (e.g. ephemeral `/tmp/esrd-feature-foo/`) → error so the
  # ephemeral esrd can't accidentally reload itself.
  defp resolve_label do
    case Esr.Paths.esrd_home() |> Path.basename() do
      ".esrd" -> {:ok, "com.ezagent.esrd"}
      ".esrd-dev" -> {:ok, "com.ezagent.esrd-dev"}
      _ -> {:error, %{"type" => "cannot_determine_label"}}
    end
  end

  # ------------------------------------------------------------------
  # Git helpers
  # ------------------------------------------------------------------

  # Resolves the current HEAD sha (short). Surfaces a git_failed error
  # if the repo isn't accessible (missing ESR_REPO_DIR, not a git
  # checkout, etc).
  defp resolve_head_sha(opts) do
    case run_git(["rev-parse", "HEAD"], opts) do
      {sha, 0} ->
        clean = String.trim(sha)

        if clean == "" do
          {:error, %{"type" => "git_failed", "detail" => "rev-parse returned empty"}}
        else
          {:ok, clean}
        end

      {out, status} ->
        {:error, %{"type" => "git_failed", "detail" => String.trim(out), "exit" => status}}
    end
  end

  # Read last_reload.yaml for the previous sha. Missing file → nil,
  # which maps to `HEAD..HEAD` (first-run empty range).
  defp read_last_sha do
    path = last_reload_path()

    case YamlElixir.read_from_file(path) do
      {:ok, %{"last_reload_sha" => sha}} when is_binary(sha) and sha != "" ->
        {:ok, sha}

      _ ->
        {:ok, nil}
    end
  end

  # git log <last>..HEAD --grep='^[^:]*!:' --grep='^BREAKING CHANGE:' --format='%h %s'
  #
  # `--grep=` is OR'd by default in git; either the subject line carries
  # the `!:` marker OR the body has `BREAKING CHANGE:`. First-run range
  # (`HEAD..HEAD`) is empty and returns no commits.
  defp scan_breaking_commits(last_sha, opts) do
    range = if last_sha, do: "#{last_sha}..HEAD", else: "HEAD..HEAD"

    argv = [
      "log",
      range,
      "--grep=^[^:]*!:",
      "--grep=^BREAKING CHANGE:",
      "--format=%h %s"
    ]

    case run_git(argv, opts) do
      {out, 0} ->
        commits =
          out
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, commits}

      {out, status} ->
        {:error, %{"type" => "git_failed", "detail" => String.trim(out), "exit" => status}}
    end
  end

  # Run `git` via the injected stub or the real System.cmd. When real,
  # use ESR_REPO_DIR if the env var is set; otherwise let git inherit
  # the runtime cwd (tests don't reach this branch).
  defp run_git(argv, opts) do
    case Keyword.get(opts, :git_fn) do
      nil ->
        cwd = System.get_env("ESR_REPO_DIR") || File.cwd!()
        System.cmd("git", argv, cd: cwd, stderr_to_stdout: true)

      f when is_function(f, 1) ->
        f.(argv)
    end
  end

  # First 7 chars of whatever git emitted (the `%h` format already
  # gives a short sha but guard against long shas in tests).
  defp short_sha(line) do
    line
    |> String.split(" ", parts: 2)
    |> List.first()
    |> to_string()
    |> String.slice(0, 7)
  end

  # ------------------------------------------------------------------
  # launchctl
  # ------------------------------------------------------------------

  # `launchctl kickstart -k gui/<uid>/<label>` — `-k` kills the
  # existing instance first, then launchd respawns it per the plist.
  # Spawned via Task.start so the call is fire-and-forget; we don't
  # block the Dispatcher Task waiting for launchd to confirm restart.
  defp kickstart(label, opts) do
    uid = System.get_env("UID") || posix_uid()
    target = "gui/#{uid}/#{label}"
    argv = ["kickstart", "-k", target]

    spawn_fn =
      Keyword.get(opts, :spawn_fn, fn a ->
        System.cmd("launchctl", a, stderr_to_stdout: true)
      end)

    _ = Task.start(fn -> spawn_fn.(argv) end)
    :ok
  end

  # Fallback when $UID isn't set — call `id -u`. Returns "501" on the
  # off-chance that fails too (devs' typical uid on macOS).
  defp posix_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "501"
    end
  rescue
    _ -> "501"
  end

  # ------------------------------------------------------------------
  # last_reload.yaml persistence
  # ------------------------------------------------------------------

  defp write_last_reload(head_sha, submitter, ack_shas, opts) do
    ts =
      Keyword.get(opts, :now_iso8601) ||
        (DateTime.utc_now() |> DateTime.to_iso8601())

    doc = %{
      "last_reload_sha" => head_sha,
      "last_reload_ts" => ts,
      "by" => submitter,
      "acknowledged_breaking" => ack_shas
    }

    Esr.Yaml.Writer.write(last_reload_path(), doc)
  end

  defp last_reload_path,
    do: Path.join(Esr.Paths.runtime_home(), "last_reload.yaml")
end

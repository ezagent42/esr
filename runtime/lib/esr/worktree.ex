defmodule Esr.Worktree do
  @moduledoc """
  Wraps `git worktree` invocations for the per-session worktree model
  (PR-21d, spec D5/D6/D7).

  Per D6, every `/new-session` forks a new branch from `origin/main` —
  not local `main` — to avoid the "operator forgot to pull" footgun.
  Per D7, the workspace's `root:` field is the source repo.

  All operations shell out via `System.cmd/3` and return either
  `:ok` / `{:ok, output}` or a structured `{:error, reason}` tuple.
  Callers (PR-21e session spawn) translate to user-facing strings.
  """
  require Logger

  @type error ::
          :root_missing
          | :root_not_a_repo
          | {:git_failed, integer(), String.t()}
          | {:already_exists, Path.t()}

  @doc """
  Add a new worktree at `cwd` forked from `origin/main` with branch
  name `branch`. Idempotent in the sense that an *exact-shape* re-add
  on an existing path returns `{:error, {:already_exists, path}}` for
  the caller to decide what to do (PR-21e: refuse the spawn).
  """
  @spec add(Path.t(), String.t(), Path.t()) :: :ok | {:error, error()}
  def add(root, branch, cwd)
      when is_binary(root) and is_binary(branch) and is_binary(cwd) do
    cond do
      not File.dir?(root) ->
        {:error, :root_missing}

      not File.dir?(Path.join(root, ".git")) and not File.exists?(Path.join(root, ".git")) ->
        # `.git` may be a directory (main worktree) or a file (linked worktree)
        {:error, :root_not_a_repo}

      File.exists?(cwd) ->
        {:error, {:already_exists, cwd}}

      true ->
        run_git(root, ["worktree", "add", cwd, "-b", branch, "origin/main"])
    end
  end

  @doc """
  Remove a worktree. Pass `force: true` (PR-21e default for clean
  worktrees) to skip the dirty-check. With `force: false`, a dirty
  worktree returns `{:error, {:git_failed, _, msg}}`.
  """
  @spec remove(Path.t(), Path.t(), keyword()) :: :ok | {:error, error()}
  def remove(root, cwd, opts \\ []) when is_binary(root) and is_binary(cwd) do
    args =
      if Keyword.get(opts, :force, false) do
        ["worktree", "remove", "--force", cwd]
      else
        ["worktree", "remove", cwd]
      end

    run_git(root, args)
  end

  @doc """
  Check whether the worktree at `cwd` has uncommitted changes.

  Returns `{:ok, :clean}` if clean, `{:ok, :dirty}` otherwise.
  Errors propagate.
  """
  @spec status(Path.t()) :: {:ok, :clean | :dirty} | {:error, error()}
  def status(cwd) when is_binary(cwd) do
    case System.cmd("git", ["-C", cwd, "status", "--porcelain"], stderr_to_stdout: true) do
      {"", 0} -> {:ok, :clean}
      {_text, 0} -> {:ok, :dirty}
      {output, code} -> {:error, {:git_failed, code, String.trim(output)}}
    end
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp run_git(root, args) do
    cmd = ["-C", root | args]

    case System.cmd("git", cmd, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {output, code} -> {:error, {:git_failed, code, String.trim(output)}}
    end
  end
end

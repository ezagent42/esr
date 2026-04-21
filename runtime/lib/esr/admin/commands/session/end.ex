defmodule Esr.Admin.Commands.Session.End do
  @moduledoc """
  `Esr.Admin.Commands.Session.End` — tears down the ephemeral esrd +
  worktree for a branch and cleans up routing/branches state
  (dev-prod-isolation spec §6.4 Session.End bullet, plan DI-10 Task 21).

  Called by `Esr.Admin.Dispatcher` inside `Task.start` when a
  `session_end`-kind command reaches the front of the queue.

  ## DI-10 scope (force-only)

  This module always passes `--force` to `scripts/esr-branch.sh end`.
  MCP `session.signal_cleanup` coordination + the 30-s interactive
  timeout UX are added in DI-11 Task 25 (which modifies this module
  to perform the cleanup-check handshake before falling through to
  the force path when the user explicitly confirms or the timeout
  fires).

  ## Flow

    1. Read `branches.yaml`. If the branch isn't registered, return
       `{:error, %{"type" => "no_such_branch"}}` without shelling out.
    2. Shell `scripts/esr-branch.sh end <branch> --force` via
       `System.cmd/3`. Script does best-effort esrd stop + `git
       worktree remove --force`.
    3. On script failure: `{:error, %{"type" => "branch_end_failed"}}`
       (includes `details` from the script's JSON error payload).
    4. On success: rewrite `branches.yaml` (drop `branches.<name>`)
       and `routing.yaml` (drop `principals[*].targets[<name>]` from
       every principal; if `principals[submitter].active == <name>`,
       unset active or fall back to the first remaining target name
       sorted alphabetically).

  ## Result

    * `{:ok, %{"branch" => name}}`
    * `{:error, %{"type" => "invalid_args"}}` — malformed command.
    * `{:error, %{"type" => "no_such_branch"}}` — branch not in
      branches.yaml.
    * `{:error, %{"type" => "branch_end_failed", "details" => msg}}` —
      script failed or JSON was unparseable.

  ## Test injection

  Same `:spawn_fn` pattern as `Esr.Admin.Commands.Session.New` and
  `Esr.Admin.Commands.RegisterAdapter`.
  """

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd), do: execute(cmd, [])

  @spec execute(map(), keyword()) :: result()
  def execute(%{"submitted_by" => submitter, "args" => %{"branch" => branch}}, opts)
      when is_binary(submitter) and is_binary(branch) and branch != "" do
    case branch_registered?(branch) do
      false ->
        {:error, %{"type" => "no_such_branch"}}

      true ->
        case call_script(branch, opts) do
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
  end

  def execute(_cmd, _opts) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "session_end requires submitted_by and args.branch (non-empty string)"
     }}
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
  # Script invocation (always --force in DI-10)
  # ------------------------------------------------------------------

  defp call_script(branch, opts) do
    argv = ["end", branch, "--force"]

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
  # Path helpers
  # ------------------------------------------------------------------

  defp branches_yaml_path, do: Path.join(Esr.Paths.runtime_home(), "branches.yaml")
  defp routing_yaml_path, do: Path.join(Esr.Paths.runtime_home(), "routing.yaml")
end

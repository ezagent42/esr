defmodule Esr.Commands.Scope.BranchNew do
  @moduledoc """
  `Esr.Commands.Scope.BranchNew` — spawns an ephemeral esrd for
  a new **branch worktree** and registers it in the routing/branches
  state (dev-prod-isolation spec §6.4 Session.New bullet, plan DI-10
  Task 20).

  PR-3 P3-8 renamed this module from `Session.New` to `Session.BranchNew`
  to free the `Session.New` name for the agent-session command (D15
  collapse). Dispatcher kind: `session_branch_new`. The agent-session
  path lives in `Esr.Commands.Scope.New` (kind `session_new`).

  Called by `Esr.Admin.Dispatcher` inside `Task.start` when a
  `session_branch_new`-kind command reaches the front of the queue.
  The Dispatcher already puts us in a Task, so blocking `System.cmd/3`
  on `scripts/esr-branch.sh` is fine — we're not holding up the
  Dispatcher GenServer.

  ## Flow

    1. Shell `scripts/esr-branch.sh new <branch>` via `System.cmd/3`.
    2. Parse the single-line JSON stdout (contract documented in
       `scripts/esr-branch.sh` header).
    3. On `ok:true`: append an entry to `branches.yaml` (under
       `branches.<sanitized_branch>`) via `Esr.Yaml.Writer` and update
       `routing.yaml` for the submitter — set
       `principals[submitted_by].active = <branch>` and add a target
       entry with the canonical `esrd_url`
       (`ws://127.0.0.1:<port>/adapter_hub/socket/websocket?vsn=2.0.0`)
       and `cc_session_id` (`<submitted_by>-<branch>`).
    4. On `ok:false`: propagate as `branch_spawn_failed`.

  ## Result

    * `{:ok, %{"branch" => name, "port" => port, "worktree_path" => path}}`
    * `{:error, %{"type" => "invalid_args", ...}}` — malformed command.
    * `{:error, %{"type" => "branch_spawn_failed", "details" => msg}}` —
      script failed or JSON was unparseable.

  ## Test injection

  `execute/2` takes an `opts` keyword where `:spawn_fn` is a 1-arity
  function receiving `{args :: [String.t()]}` and returning
  `{stdout :: String.t(), exit :: integer()}` — the same shape
  `System.cmd/3` returns. Tests pass a stub; production calls
  `execute/1` which uses the real `System.cmd/3`. Mirrors the
  `:spawn_fn` pattern in `Esr.Commands.RegisterAdapter`.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd), do: execute(cmd, [])

  @spec execute(map(), keyword()) :: result()
  def execute(%{"submitted_by" => submitter, "args" => %{"branch" => branch_raw} = args}, opts)
      when is_binary(submitter) and is_binary(branch_raw) and branch_raw != "" do
    script_args = build_script_args(branch_raw, args)

    case call_script(script_args, opts) do
      {:ok, json_map} ->
        persist_and_reply(json_map, submitter)

      {:error, _} = err ->
        err
    end
  end

  def execute(_cmd, _opts) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" =>
         "session_branch_new requires submitted_by and args.branch (non-empty string)"
     }}
  end

  # ------------------------------------------------------------------
  # Script invocation
  # ------------------------------------------------------------------

  # Builds the argv for esr-branch.sh. The optional --worktree-base flag
  # lets callers override the default `.claude/worktrees` (mostly for
  # tests, but also exposed for operators who want a different layout).
  defp build_script_args(branch_raw, args) do
    base_flag =
      case args["worktree_base"] do
        nil -> []
        "" -> []
        v when is_binary(v) -> ["--worktree-base=#{v}"]
        _ -> []
      end

    ["new", branch_raw | base_flag]
  end

  # Invokes the script (or the injected stub) and parses JSON. Missing /
  # malformed output is classified as branch_spawn_failed so the operator
  # sees one stable error type regardless of script failure mode.
  defp call_script(script_args, opts) do
    spawn_fn =
      Keyword.get(opts, :spawn_fn, fn {argv} ->
        System.cmd(script_path(), argv, stderr_to_stdout: true)
      end)

    {output, exit_status} = spawn_fn.({script_args})

    case Jason.decode(output) do
      {:ok, %{"ok" => true} = m} when exit_status == 0 ->
        {:ok, m}

      {:ok, %{"ok" => false, "error" => msg}} ->
        {:error, %{"type" => "branch_spawn_failed", "details" => to_string(msg)}}

      {:ok, other} ->
        {:error,
         %{"type" => "branch_spawn_failed", "details" => "unexpected script payload: " <> inspect(other)}}

      {:error, %Jason.DecodeError{} = err} ->
        {:error,
         %{
           "type" => "branch_spawn_failed",
           "details" => "malformed JSON stdout: " <> Exception.message(err)
         }}
    end
  end

  # Resolves the on-disk path to scripts/esr-branch.sh by walking up from
  # the runtime app priv dir to the repo root. Relies on the repo layout
  # having `scripts/` at the top level (true for ESR as of v0.2).
  defp script_path do
    repo_root =
      :esr
      |> Application.app_dir()
      |> Path.join("../../../..")
      |> Path.expand()

    Path.join([repo_root, "scripts", "esr-branch.sh"])
  end

  # ------------------------------------------------------------------
  # YAML persistence
  # ------------------------------------------------------------------

  defp persist_and_reply(%{"branch" => branch, "port" => port} = json, submitter)
       when is_binary(branch) and is_integer(port) do
    worktree = json["worktree_path"] || ""
    esrd_home = json["esrd_home"] || ""
    kind = json["kind"] || "ephemeral"

    with :ok <- append_branches_yaml(branch, port, worktree, esrd_home, kind),
         :ok <- upsert_routing_yaml(submitter, branch, port) do
      {:ok,
       %{
         "branch" => branch,
         "port" => port,
         "worktree_path" => worktree
       }}
    else
      {:error, reason} ->
        {:error,
         %{"type" => "branch_spawn_failed", "details" => "yaml persist failed: " <> inspect(reason)}}
    end
  end

  defp persist_and_reply(other, _submitter) do
    {:error,
     %{
       "type" => "branch_spawn_failed",
       "details" => "script payload missing branch/port: " <> inspect(other)
     }}
  end

  defp append_branches_yaml(branch, port, worktree, esrd_home, kind) do
    path = branches_yaml_path()

    current =
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = m} -> m
        _ -> %{"branches" => %{}}
      end

    branches = Map.get(current, "branches") || %{}

    entry = %{
      "esrd_home" => esrd_home,
      "worktree_path" => worktree,
      "port" => port,
      "spawned_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "status" => "running",
      "kind" => kind
    }

    updated = Map.put(current, "branches", Map.put(branches, branch, entry))
    Esr.Yaml.Writer.write(path, updated)
  end

  defp upsert_routing_yaml(submitter, branch, port) do
    path = routing_yaml_path()

    current =
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = m} -> m
        _ -> %{"principals" => %{}}
      end

    principals = Map.get(current, "principals") || %{}
    existing = Map.get(principals, submitter) || %{}
    existing_targets = Map.get(existing, "targets") || %{}

    target = %{
      "esrd_url" =>
        "ws://127.0.0.1:" <> Integer.to_string(port) <> "/adapter_hub/socket/websocket?vsn=2.0.0",
      "cc_session_id" => submitter <> "-" <> branch,
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    updated_principal =
      existing
      |> Map.put("active", branch)
      |> Map.put("targets", Map.put(existing_targets, branch, target))

    updated =
      Map.put(current, "principals", Map.put(principals, submitter, updated_principal))

    Esr.Yaml.Writer.write(path, updated)
  end

  # ------------------------------------------------------------------
  # Path helpers — delegate to Esr.Paths when available, otherwise
  # compose from runtime_home (the only thing guaranteed to exist).
  # ------------------------------------------------------------------

  defp branches_yaml_path, do: Path.join(Esr.Paths.runtime_home(), "branches.yaml")
  defp routing_yaml_path, do: Path.join(Esr.Paths.runtime_home(), "routing.yaml")
end

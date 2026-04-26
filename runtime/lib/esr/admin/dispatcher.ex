defmodule Esr.Admin.Dispatcher do
  @moduledoc """
  Admin subsystem brain (spec §6.2).

  Receives commands via two async paths — both `GenServer.cast` —
  from `Esr.Admin.CommandQueue.Watcher` (file-based CLI queue) and
  `Esr.Peers.SlashHandler` (Feishu slash-command path, P3-14 onward —
  previously `Esr.Routing.SlashHandler`). Both paths supply
  `{:execute, command, {:reply_to, target}}` where `target` is one of:

    * `{:file, completed_path}` — the CLI queue case. Dispatcher
      writes the result onto the queue file (already moved to
      `completed/` or `failed/`) so the CLI's `--wait` polling loop
      sees it.
    * `{:pid, router_pid, ref}` — the Feishu case. Dispatcher `send`s
      `{:command_result, ref, result}` back to the router, which emits
      a Feishu reply at that point.

  Execution flow (§6.2):

    1. Parse `kind` / `submitted_by` / `id` / `args` from the command.
    2. Capability-check via `Esr.Capabilities.has?/2` using the
       `required_permission(kind)` map below. On `false`: move the
       queue file `pending/<id>.yaml` → `failed/<id>.yaml` synchronously,
       emit telemetry, and deliver `{:error, %{type: "unauthorized"}}`
       to the reply target. No `Task.start`.
    3. Move the queue file `pending/<id>.yaml` → `processing/<id>.yaml`
       synchronously so restart recovery sees a consistent in-flight
       view.
    4. `Task.start(fn -> run_and_report(...) end)` runs the command's
       `Esr.Admin.Commands.<Kind>.execute/1` outside the Dispatcher
       process (commands can block for seconds — `reload` up to 30s)
       and sends `{:command_result, id, result}` back.
    5. On `{:command_result, id, result}`: move the queue file
       `processing/<id>.yaml` → `completed/<id>.yaml` or
       `failed/<id>.yaml`, serialize the result onto the destination
       file for file-reply targets (`send/2` for pid-reply targets),
       and emit the `:command_executed` / `:command_failed` telemetry.

  Secret redaction (Task 14b / DI-7b): before the completed or failed
  queue file is written to disk, `args.app_secret`, `args.secret` and
  `args.token` are overwritten with the string `"[redacted_post_exec]"`
  so secrets supplied in the submitted command don't leak onto the
  filesystem after execution. Telemetry (`:command_executed` /
  `:command_failed`) carries `kind`, `submitted_by`, and `duration_ms`
  per spec §10.
  """

  # Sentinel value written in place of any secret-ish arg key on the
  # completed/failed queue file. Listed once so tests and callers can
  # import a single canonical value.
  @redacted_post_exec "[redacted_post_exec]"
  @secret_arg_keys ["app_secret", "secret", "token"]

  @doc "Sentinel string written in place of secret-ish args post-exec."
  def redacted_post_exec, do: @redacted_post_exec

  @doc "Arg keys whose values are redacted when the queue file is written out."
  def secret_arg_keys, do: @secret_arg_keys
  use GenServer
  require Logger

  # kind → required permission (spec §6.2 table).
  #
  # PR-3 P3-8.7: `session_new` now means the **agent-session** command
  # (`Esr.Admin.Commands.Session.New`, formerly Session.AgentNew); the
  # legacy branch-worktree path is `session_branch_new`. Both share the
  # `session:default/create` permission (canonical prefix:name/perm form
  # required by `Grants.matches?/2`). Legacy `session.create` dotted
  # permission strings are still accepted via wildcard grants (`"*"`),
  # which every test principal uses.
  #
  # PR-3 P3-9.3: `session_end` now means the **agent-session** teardown
  # command (`Esr.Admin.Commands.Session.End`, delegating to
  # `Esr.SessionRouter.end_session/1`); the legacy branch-worktree
  # teardown path is `session_branch_end`. Both share the canonical
  # `session:default/end` permission.
  @required_permissions %{
    "notify" => "notify.send",
    "reload" => "runtime.reload",
    "register_adapter" => "adapter.register",
    "session_new" => "session:default/create",
    "session_branch_new" => "session:default/create",
    "session_switch" => "session.switch",
    "session_end" => "session:default/end",
    "session_branch_end" => "session:default/end",
    "session_list" => "session.list",
    "grant" => "cap.manage",
    "revoke" => "cap.manage",
    # PR-A T9: cross_app_test is e2e-only; gate behind a wildcard-
    # only permission so it can't fire under non-test grants.
    "cross_app_test" => "cross_app_test.invoke"
  }

  # Map kind → Commands.<Module>. Missing entries surface as
  # {:error, %{type: "unknown_kind"}} so unsupported kinds fail fast.
  #
  # PR-3 P3-8: `session_new` → `Session.New` (agent-session, formerly
  # AgentNew); `session_branch_new` → `Session.BranchNew` (the renamed
  # legacy branch-worktree command).
  #
  # PR-3 P3-9: `session_end` → `Session.End` (agent-session teardown via
  # SessionRouter); `session_branch_end` → `Session.BranchEnd` (the
  # renamed legacy branch-worktree teardown command).
  @command_modules %{
    "notify" => Esr.Admin.Commands.Notify,
    "reload" => Esr.Admin.Commands.Reload,
    "register_adapter" => Esr.Admin.Commands.RegisterAdapter,
    "session_new" => Esr.Admin.Commands.Session.New,
    "session_branch_new" => Esr.Admin.Commands.Session.BranchNew,
    "session_switch" => Esr.Admin.Commands.Session.Switch,
    "session_end" => Esr.Admin.Commands.Session.End,
    "session_branch_end" => Esr.Admin.Commands.Session.BranchEnd,
    "session_list" => Esr.Admin.Commands.Session.List,
    "grant" => Esr.Admin.Commands.Cap.Grant,
    "revoke" => Esr.Admin.Commands.Cap.Revoke,
    # PR-A T9: e2e-only test-harness command — synthesizes a
    # tool_invoke into FCP, bypassing claude. See
    # Esr.Admin.Commands.CrossAppTest for rationale.
    "cross_app_test" => Esr.Admin.Commands.CrossAppTest
  }

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{pending: %{}, pending_cleanups: %{}}}

  @doc """
  Register the current process as the Task awaiting a `:cleanup_signal`
  for `session_id`. Called by `Esr.Admin.Commands.Session.BranchEnd`
  (the legacy branch-worktree path, formerly `Session.End` before the
  PR-3 P3-9 rename) on its non-force branch (DI-11 Task 25) before it
  blocks on `receive`.

  Dispatcher stores `session_id → task_pid` in `state.pending_cleanups`
  so an inbound `{:cleanup_signal, session_id, status, details}` message
  (delivered by the `session.signal_cleanup` MCP tool — Task 24) can
  be forwarded to the right Task. Entries are removed on delivery; the
  caller's 30-s `receive ... after` backs this up if a signal never
  arrives.
  """
  @spec register_cleanup(String.t(), pid()) :: :ok
  def register_cleanup(session_id, task_pid)
      when is_binary(session_id) and is_pid(task_pid) do
    GenServer.cast(__MODULE__, {:register_cleanup, session_id, task_pid})
  end

  @doc """
  Deregister a pending cleanup — used by `Session.BranchEnd` on timeout
  or after the signal has been consumed, so the Dispatcher doesn't keep
  a stale `session_id → pid` mapping around.
  """
  @spec deregister_cleanup(String.t()) :: :ok
  def deregister_cleanup(session_id) when is_binary(session_id) do
    GenServer.cast(__MODULE__, {:deregister_cleanup, session_id})
  end

  # ------------------------------------------------------------------
  # Cast — enqueue a command
  # ------------------------------------------------------------------

  @impl true
  def handle_cast({:execute, command, reply_to}, state) when is_map(command) do
    id = command["id"] || "no-id-#{System.unique_integer([:positive])}"
    kind = command["kind"]
    submitted_by = command["submitted_by"] || "ou_unknown"

    required = @required_permissions[kind]

    cond do
      is_nil(kind) or not is_binary(kind) ->
        unauthorized_or_error(id, command, reply_to, {:error, %{"type" => "invalid_kind"}}, state)

      is_nil(required) ->
        unauthorized_or_error(
          id,
          command,
          reply_to,
          {:error, %{"type" => "unknown_kind", "kind" => kind}},
          state
        )

      not Esr.Capabilities.has?(submitted_by, required) ->
        unauthorized_or_error(
          id,
          command,
          reply_to,
          {:error, %{"type" => "unauthorized", "kind" => kind, "required" => required}},
          state
        )

      true ->
        # Happy path: move pending → processing, spawn the Task.
        case move_pending_to_processing(id) do
          :ok ->
            start_time = System.monotonic_time(:millisecond)
            self_pid = self()

            _ =
              Task.start(fn ->
                result = run_command(kind, command)
                send(self_pid, {:command_result, id, result})
              end)

            state =
              put_in(state.pending[id], %{
                command: command,
                reply_to: reply_to,
                start_time: start_time
              })

            {:noreply, state}

          {:error, reason} ->
            # Queue file missing — synthesize an immediate failure so the
            # reply_to target still gets a result. This keeps Dispatcher
            # usable from tests that bypass the on-disk queue.
            err = {:error, %{"type" => "queue_file_missing", "detail" => inspect(reason)}}

            deliver_immediate(id, command, reply_to, err)
            {:noreply, state}
        end
    end
  end

  # DI-11 Task 25: track the Task pid that is currently waiting on a
  # `:cleanup_signal` for a given `session_id` (convention:
  # `"<submitter>-<branch>"`, same as `cc_session_id` in `routing.yaml`).
  # The mapping is overwritten on duplicate registrations — if a second
  # `/end-session` comes in for the same branch while the first is still
  # blocked, only the latest Task is addressable; the older one will
  # fall through to its 30-s `after` clause. This mirrors the realistic
  # UX (only one interactive prompt per branch at a time).
  def handle_cast({:register_cleanup, session_id, task_pid}, state) do
    {:noreply, put_in(state.pending_cleanups[session_id], task_pid)}
  end

  def handle_cast({:deregister_cleanup, session_id}, state) do
    {:noreply, %{state | pending_cleanups: Map.delete(state.pending_cleanups, session_id)}}
  end

  # ------------------------------------------------------------------
  # Info — Task result
  # ------------------------------------------------------------------

  @impl true
  def handle_info({:command_result, id, result}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        Logger.warning("admin.dispatcher: stray command_result id=#{id}")
        {:noreply, state}

      {pending, rest} ->
        %{command: command, reply_to: reply_to, start_time: start_time} = pending

        dest_dir = if match?({:ok, _}, result), do: "completed", else: "failed"
        move_processing_to(dest_dir, id)
        write_result_to_file_target(reply_to, dest_dir, id, command, result)
        reply_to_pid_target(reply_to, id, result)

        emit_telemetry(result, command, start_time)

        {:noreply, %{state | pending: rest}}
    end
  end

  # DI-11 Task 25: route the cleanup signal emitted by the
  # `session.signal_cleanup` MCP tool (Task 24) back to the Task that
  # is blocking inside `Session.BranchEnd.execute/2`. Drops the
  # session_id entry after delivery — a second signal with no pending
  # waiter falls through to the catch-all below.
  def handle_info({:cleanup_signal, session_id, status, details}, state)
      when is_binary(session_id) and is_binary(status) do
    case Map.pop(state.pending_cleanups, session_id) do
      {nil, _} ->
        Logger.warning(
          "admin.dispatcher: :cleanup_signal for session_id=#{session_id} " <>
            "status=#{status} with no pending waiter (race or stray signal)"
        )

        {:noreply, state}

      {task_pid, rest} when is_pid(task_pid) ->
        if Process.alive?(task_pid) do
          send(task_pid, {:cleanup_signal, status, details})
        else
          Logger.warning(
            "admin.dispatcher: :cleanup_signal for session_id=#{session_id} " <>
              "found dead waiter pid — dropping"
          )
        end

        {:noreply, %{state | pending_cleanups: rest}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  # Shared no-Task failure path: cap-check failure or malformed command.
  # Moves pending → failed (best-effort; tests that bypass the queue
  # have no pending file and that's fine), delivers the error to the
  # reply target, and emits the failure telemetry.
  defp unauthorized_or_error(id, command, reply_to, {:error, _} = result, state) do
    move_pending_to(id, "failed")
    write_result_to_file_target(reply_to, "failed", id, command, result)
    reply_to_pid_target(reply_to, id, result)
    emit_telemetry(result, command, System.monotonic_time(:millisecond))
    {:noreply, state}
  end

  # When the queue file is missing (test / programmatic cast), there's
  # nothing to move. Deliver the result inline and emit telemetry.
  defp deliver_immediate(id, command, reply_to, result) do
    write_result_to_file_target(reply_to, "failed", id, command, result)
    reply_to_pid_target(reply_to, id, result)
    emit_telemetry(result, command, System.monotonic_time(:millisecond))
  end

  defp run_command(kind, command) do
    case Map.fetch(@command_modules, kind) do
      {:ok, mod} ->
        try do
          mod.execute(command)
        rescue
          exc ->
            {:error,
             %{
               "type" => "command_crashed",
               "kind" => kind,
               "message" => Exception.message(exc)
             }}
        end

      :error ->
        {:error, %{"type" => "unknown_kind", "kind" => kind}}
    end
  end

  # pending/<id>.yaml → processing/<id>.yaml
  defp move_pending_to_processing(id) do
    base = Esr.Paths.admin_queue_dir()
    src = Path.join([base, "pending", "#{id}.yaml"])
    dst = Path.join([base, "processing", "#{id}.yaml"])

    cond do
      File.exists?(src) ->
        _ = File.mkdir_p(Path.dirname(dst))
        File.rename(src, dst)

      File.exists?(dst) ->
        # Already moved (e.g. watcher re-fired) — treat as success.
        :ok

      true ->
        # Not on disk — tests may cast directly.
        :ok
    end
  end

  # pending/<id>.yaml → <dest_dir>/<id>.yaml (cap-check failure path).
  defp move_pending_to(id, dest_dir) do
    base = Esr.Paths.admin_queue_dir()
    src = Path.join([base, "pending", "#{id}.yaml"])
    dst = Path.join([base, dest_dir, "#{id}.yaml"])

    if File.exists?(src) do
      _ = File.mkdir_p(Path.dirname(dst))
      _ = File.rename(src, dst)
    end

    :ok
  end

  # processing/<id>.yaml → <dest_dir>/<id>.yaml.
  defp move_processing_to(dest_dir, id) do
    base = Esr.Paths.admin_queue_dir()
    src = Path.join([base, "processing", "#{id}.yaml"])
    dst = Path.join([base, dest_dir, "#{id}.yaml"])

    if File.exists?(src) do
      _ = File.mkdir_p(Path.dirname(dst))
      _ = File.rename(src, dst)
    end

    :ok
  end

  # For `{:file, _path}` reply targets — serialize the command doc +
  # result + completed_at stamp and write it on top of the destination
  # file (which was already moved into completed/ or failed/).
  defp write_result_to_file_target(
         {:reply_to, {:file, _completed_path}},
         dest_dir,
         id,
         command,
         result
       ) do
    base = Esr.Paths.admin_queue_dir()
    dest = Path.join([base, dest_dir, "#{id}.yaml"])

    doc =
      command
      |> Map.merge(%{
        "result" => result_to_map(result),
        "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
      |> redact_secrets()

    case Esr.Yaml.Writer.write(dest, doc) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("admin.dispatcher: write result failed id=#{id}: #{inspect(reason)}")
        :ok
    end
  end

  defp write_result_to_file_target(_other, _dest_dir, _id, _command, _result), do: :ok

  # For `{:pid, pid, ref}` reply targets — send back to the router.
  defp reply_to_pid_target({:reply_to, {:pid, pid, ref}}, _id, result)
       when is_pid(pid) and is_reference(ref) do
    send(pid, {:command_result, ref, result})
    :ok
  end

  defp reply_to_pid_target(_other, _id, _result), do: :ok

  # {:ok | :error, map} → plain map the Yaml writer can serialize.
  defp result_to_map({:ok, %{} = m}), do: Map.merge(%{"ok" => true}, stringify_keys(m))
  defp result_to_map({:error, %{} = m}), do: Map.merge(%{"ok" => false}, stringify_keys(m))
  defp result_to_map({:ok, other}), do: %{"ok" => true, "value" => inspect(other)}
  defp result_to_map({:error, other}), do: %{"ok" => false, "error" => inspect(other)}
  defp result_to_map(other), do: %{"ok" => false, "error" => inspect(other)}

  defp stringify_keys(map) when is_map(map) do
    for {k, v} <- map, into: %{} do
      {to_string(k), v}
    end
  end

  # Overwrite args.{app_secret,secret,token} with the redaction sentinel
  # so secrets submitted in the queue YAML don't get written back onto
  # completed/<id>.yaml or failed/<id>.yaml. Accepts both string-keyed
  # ("args" — the normal on-disk shape) and atom-keyed (:args — possible
  # in unit tests that bypass YAML) shapes.
  defp redact_secrets(%{"args" => args} = doc) when is_map(args) do
    %{doc | "args" => redact_args(args)}
  end

  defp redact_secrets(%{args: args} = doc) when is_map(args) do
    %{doc | args: redact_args(args)}
  end

  defp redact_secrets(doc), do: doc

  defp redact_args(args) do
    for {k, v} <- args, into: %{} do
      if to_string(k) in @secret_arg_keys, do: {k, @redacted_post_exec}, else: {k, v}
    end
  end

  defp emit_telemetry(result, command, start_time) do
    event =
      case result do
        {:ok, _} -> :command_executed
        _ -> :command_failed
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:esr, :admin, event],
      %{count: 1, duration_ms: duration_ms},
      %{kind: command["kind"], submitted_by: command["submitted_by"]}
    )
  end
end

defmodule Esr.Slash.QueueResult do
  @moduledoc """
  Phase 2 PR-2.3a: pure-function module owning the admin-queue file
  state machine + secret redaction.

  Pre-PR-2.3a these concerns lived inside `Esr.Admin.Dispatcher`; the
  spec subagent-review (2026-05-05) flagged that Dispatcher conflated
  dispatch + cleanup-signal + secret-redaction + file-state-machine,
  and recommended splitting into single-purpose modules. This is the
  file/redaction half (the cleanup half lives in
  `Esr.Slash.CleanupRendezvous`).

  ## State machine

      pending/<id>.yaml
          ↓ start_processing/1
      processing/<id>.yaml
          ↓ finish/3 (dest_dir = "completed" | "failed")
      <dest_dir>/<id>.yaml  (with merged result + completed_at + redaction)

  Cap-check failures take a shortcut: `move_pending_to/2` jumps
  directly from pending → failed without going through processing
  (since execute/2 never ran).

  ## Redaction

  Before writing to the destination file, the document's `args` map
  has known secret keys overwritten with the sentinel
  `[redacted_post_exec]`. Today the keyset is `app_secret`, `secret`,
  `token`. Adding a new key just means appending to
  `secret_arg_keys/0`. Per North Star: this list should eventually
  move into the slash-routes.yaml schema (each arg can declare
  `secret: true`), so plugins introducing new secret arg names
  don't need to edit core. Out of scope for PR-2.3a.

  ## Stub status

  PR-2.3a defines the module + tests. Dispatcher still owns the
  actual file moves at runtime. PR-2.3b deletes Dispatcher and points
  the (renamed) Watcher at this module's API.

  ## Public API

    * `start_processing/1` — pending/<id>.yaml → processing/<id>.yaml
    * `move_pending_to/2`  — pending/<id>.yaml → <dest_dir>/<id>.yaml
                            (cap-check failure shortcut)
    * `finish/3`           — processing/<id>.yaml → <dest_dir>/<id>.yaml
                            with merged result doc + redaction
    * `recover_stale/0`    — boot-time sweep: any orphan
                            `processing/<id>.yaml` (esrd died mid-exec)
                            is moved to `failed/` so the watcher
                            doesn't loop on it.
    * `secret_arg_keys/0`  — public accessor for the redaction set.
    * `redacted_post_exec/0` — the sentinel string itself.
  """

  require Logger

  @redacted_post_exec "[redacted_post_exec]"
  @secret_arg_keys ~w(app_secret secret token)

  @doc "The sentinel string used to overwrite redacted argument values."
  def redacted_post_exec, do: @redacted_post_exec

  @doc "Arg keys whose values are redacted on persist."
  def secret_arg_keys, do: @secret_arg_keys

  @doc """
  Move `pending/<id>.yaml` to `processing/<id>.yaml`. Returns `:ok`
  even if the source isn't on disk (tests cast directly to dispatchers
  bypassing the queue).
  """
  @spec start_processing(String.t()) :: :ok | {:error, term()}
  def start_processing(id) when is_binary(id) do
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

  @doc """
  Move `pending/<id>.yaml` directly to `<dest_dir>/<id>.yaml` (used
  for cap-check failures that never reach processing). No-op if the
  source isn't on disk. Returns `:ok` always.
  """
  @spec move_pending_to(String.t(), String.t()) :: :ok
  def move_pending_to(id, dest_dir) when is_binary(id) and is_binary(dest_dir) do
    base = Esr.Paths.admin_queue_dir()
    src = Path.join([base, "pending", "#{id}.yaml"])
    dst = Path.join([base, dest_dir, "#{id}.yaml"])

    if File.exists?(src) do
      _ = File.mkdir_p(Path.dirname(dst))
      _ = File.rename(src, dst)
    end

    :ok
  end

  @doc """
  Atomically: move `processing/<id>.yaml` to `<dest_dir>/<id>.yaml`,
  then write the supplied document on top of the moved file. The doc
  is merged with `completed_at` and run through redaction before
  serialization.

  `dest_dir` is `"completed"` for `{:ok, _}` results, `"failed"` for
  errors.

  Returns `:ok` on success or after a non-fatal write failure (the
  move + best-effort write mirror today's Dispatcher semantics, which
  log but never crash on serialization issues).
  """
  @spec finish(String.t(), String.t(), map()) :: :ok
  def finish(id, dest_dir, doc)
      when is_binary(id) and is_binary(dest_dir) and is_map(doc) do
    base = Esr.Paths.admin_queue_dir()
    src = Path.join([base, "processing", "#{id}.yaml"])
    dst = Path.join([base, dest_dir, "#{id}.yaml"])

    if File.exists?(src) do
      _ = File.mkdir_p(Path.dirname(dst))
      _ = File.rename(src, dst)
    end

    full_doc =
      doc
      |> Map.put_new("completed_at", DateTime.utc_now() |> DateTime.to_iso8601())
      |> redact_secrets()

    case Esr.Yaml.Writer.write(dst, full_doc) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("queue_result: write failed id=#{id}: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Boot-time recovery: any file in `processing/` is left over from an
  esrd that died mid-execution. Move each to `failed/` with a
  synthetic error doc so the watcher doesn't loop on it.

  Returns the count of recovered files.
  """
  @spec recover_stale() :: non_neg_integer()
  def recover_stale do
    base = Esr.Paths.admin_queue_dir()
    proc_dir = Path.join(base, "processing")

    case File.ls(proc_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".yaml"))
        |> Enum.map(fn file ->
          id = String.replace_suffix(file, ".yaml", "")
          recover_one(id)
        end)
        |> Enum.count()

      {:error, _} ->
        0
    end
  end

  defp recover_one(id) do
    base = Esr.Paths.admin_queue_dir()
    src = Path.join([base, "processing", "#{id}.yaml"])

    case YamlElixir.read_from_file(src) do
      {:ok, parsed} when is_map(parsed) ->
        doc =
          parsed
          |> Map.put("result", %{
            "ok" => false,
            "error" => "interrupted_at_boot",
            "detail" => "esrd restart with this command in processing/"
          })

        finish(id, "failed", doc)

      _ ->
        # Corrupt yaml — just rename and move on.
        dst = Path.join([base, "failed", "#{id}.yaml"])
        _ = File.mkdir_p(Path.dirname(dst))
        _ = File.rename(src, dst)
        :ok
    end
  end

  # Overwrite args.{app_secret, secret, token} with the redaction sentinel.
  # Accepts both string-keyed ("args" — on-disk shape) and atom-keyed
  # (:args — possible in tests bypassing YAML).
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
end

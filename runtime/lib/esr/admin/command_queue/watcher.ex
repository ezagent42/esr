defmodule Esr.Admin.CommandQueue.Watcher do
  @moduledoc """
  GenServer that watches `<admin_queue_dir>/pending/` for new command
  YAML files written by the CLI (see spec §6.3 and §6.8).

  Filter rules on each `:file_event`:

    1. Basenames ending in `.tmp` are staging files from the CLI's
       atomic-write dance (`<ulid>.yaml.tmp` then rename to
       `<ulid>.yaml`) — ignored.
    2. Any non-`.yaml` basename is ignored.
    3. Otherwise: debounce 50ms so the post-rename `file_created`
       event and residual writes coalesce, then read the YAML and
       call `Esr.Entity.SlashHandler.dispatch_command/2` with a
       `{Esr.Slash.ReplyTarget.QueueFile, %{id, command}}` reply
       target. The QueueFile impl uses
       `Esr.Slash.QueueResult.finish/3` to atomically move +
       write the result yaml on the destination file. On YAML
       parse failure, log and continue.

  PR-2.3b-2 deleted the legacy `Esr.Admin.Dispatcher` named
  GenServer; this module now drives the unified SlashHandler
  dispatch path directly.

  On `init/1` the Watcher additionally runs two recovery sweeps
  (spec §9.3, plan DI-7b Task 14d):

    * `scan_pending_orphans/1` — any `pending/*.yaml` already on disk
      at boot is re-cast to the Dispatcher. Covers the window
      between the CLI's atomic write and the Watcher arming its
      FileSystem subscription, during which an `esrd` kill would
      otherwise strand the command.

    * `scan_stale_processing/0` — any `processing/*.yaml` whose
      mtime is older than 10 minutes is renamed back to `pending/`.
      Covers "Dispatcher crashed mid-command" — the moved file then
      rides the pending-orphan sweep on the next boot (or is picked
      up immediately by the freshly-armed FileSystem subscription
      on this one).

  Commands are required to be idempotent (§9.3), so re-dispatch is
  safe — re-running `session_new` on an existing branch is a no-op,
  `register_adapter` with identical args replaces the same
  adapters.yaml entry, etc.

  SlashHandler is registered under `:slash_handler` in
  `Esr.Scope.Admin.Process` and is started before this Watcher by
  `Esr.Application` boot order, so the cast always lands on a live
  named process.
  """
  use GenServer
  require Logger

  # Processing files older than this are considered stranded by a
  # Dispatcher crash and are moved back to `pending/` on boot.
  @stale_processing_seconds 10 * 60

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    admin_dir = Esr.Paths.admin_queue_dir()
    pending_dir = Path.join(admin_dir, "pending")
    processing_dir = Path.join(admin_dir, "processing")

    File.mkdir_p!(pending_dir)
    File.mkdir_p!(processing_dir)
    File.mkdir_p!(Path.join(admin_dir, "completed"))
    File.mkdir_p!(Path.join(admin_dir, "failed"))

    # Synchronous file-rename sweep (no deps): move stale processing/
    # entries back to pending/ so the orphan-dispatch sweep below
    # picks them up.
    scan_stale_processing(processing_dir, pending_dir)

    {:ok, pid} = FileSystem.start_link(dirs: [pending_dir])
    FileSystem.subscribe(pid)
    Logger.info("admin.watcher: watching #{pending_dir}")

    # PR-2.3b-2: defer the dispatch-driven sweep to handle_continue so
    # that even though Esr.Slash.HandlerBootstrap (an earlier child
    # in Esr.Application's children list) already registered
    # SlashHandler synchronously, we keep the dispatch off the init
    # path. This also means tests that start Watcher directly need
    # to call :sys.get_state/1 before asserting orphan-dispatch
    # side-effects.
    {:ok, %{fs_pid: pid, pending_dir: pending_dir, processing_dir: processing_dir},
     {:continue, :scan_orphans}}
  end

  @impl true
  def handle_continue(:scan_orphans, state) do
    scan_pending_orphans(state.pending_dir)
    {:noreply, state}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, _events}}, state) do
    basename = Path.basename(path)

    cond do
      String.ends_with?(basename, ".tmp") ->
        {:noreply, state}

      not String.ends_with?(basename, ".yaml") ->
        {:noreply, state}

      true ->
        # Debounce so the rename-driven `:created` event and any
        # residual writes coalesce before we read.
        Process.sleep(50)
        dispatch_pending_file(path, basename)
        {:noreply, state}
    end
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # Boot-time recovery sweeps (spec §9.3, plan DI-7b Task 14d)
  # ------------------------------------------------------------------

  defp scan_pending_orphans(pending_dir) do
    case File.ls(pending_dir) do
      {:ok, entries} ->
        for file <- entries, String.ends_with?(file, ".yaml") do
          full = Path.join(pending_dir, file)
          Logger.info("admin.watcher: recovering pending orphan #{file}")
          dispatch_pending_file(full, file)
        end

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp scan_stale_processing(processing_dir, pending_dir) do
    cutoff = System.system_time(:second) - @stale_processing_seconds

    case File.ls(processing_dir) do
      {:ok, entries} ->
        for file <- entries, String.ends_with?(file, ".yaml") do
          full = Path.join(processing_dir, file)

          case File.stat(full, time: :posix) do
            {:ok, %{mtime: mt}} when mt < cutoff ->
              dest = Path.join(pending_dir, file)

              Logger.warning(
                "admin.watcher: processing/#{file} is stale (mtime=#{mt}, cutoff=#{cutoff}); returning to pending/"
              )

              case File.rename(full, dest) do
                :ok ->
                  :ok

                {:error, reason} ->
                  Logger.error(
                    "admin.watcher: failed to rename #{full} -> #{dest}: #{inspect(reason)}"
                  )
              end

            _ ->
              :ok
          end
        end

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  # Read a `pending/<basename>.yaml` and dispatch through SlashHandler
  # using the QueueFile reply target. Shared by the live fs-event
  # path and the boot-time recovery sweep.
  defp dispatch_pending_file(path, basename) do
    case YamlElixir.read_from_file(path) do
      {:ok, cmd} when is_map(cmd) ->
        id = String.replace_suffix(basename, ".yaml", "")
        # Move pending → processing first so QueueResult.finish/3
        # finds the file in processing/ when the result lands.
        :ok = Esr.Slash.QueueResult.start_processing(id)

        target = {Esr.Slash.ReplyTarget.QueueFile, %{id: id, command: cmd}}
        _ref = Esr.Entity.SlashHandler.dispatch_command(cmd, target)
        :ok

      {:ok, _bad} ->
        Logger.error("admin.watcher: yaml does not parse to a map at #{path}")

      {:error, err} ->
        Logger.error("admin.watcher: bad yaml #{path}: #{inspect(err)}")
    end
  end
end

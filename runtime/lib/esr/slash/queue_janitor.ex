defmodule Esr.Slash.QueueJanitor do
  @moduledoc """
  Nightly cleanup sweep of `admin_queue/{completed,failed}/`.

  Spec §9.6 — completed and failed queue YAMLs stay on disk for
  forensic / replay use, but only up to
  `$ESR_ADMIN_QUEUE_RETENTION_DAYS` (default **14**) days. Anything
  older is removed.

  Runs as a supervised `GenServer` under `Esr.Slash.Supervisor` and
  schedules itself every 24h. `sweep/1` is exposed as a public API so
  tests (and an eventual admin command) can drive a sweep without
  waiting for the next tick.

  Implementation notes:

    * File age is determined via `File.stat/2` with `time: :posix`,
      comparing `mtime` to a cutoff computed from
      `System.system_time(:second)`. This matches how the Dispatcher
      writes completed/failed files (rename preserves mtime from the
      original write) and avoids UTC/local calendar arithmetic.
    * If a directory does not yet exist (first boot, disposable tmp
      ESRD_HOME in tests) the sweep silently no-ops for that
      directory — the Watcher `mkdir_p!`s on init, so in production
      both will exist by the time we fire.
    * Failures to `File.rm/1` are logged but do not crash the
      GenServer; a transient permission hiccup must not poison the
      Admin supervisor's `:rest_for_one` tree.
  """
  use GenServer
  require Logger

  @default_retention_days 14
  @sweep_interval_ms :timer.hours(24)

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    days =
      System.get_env("ESR_ADMIN_QUEUE_RETENTION_DAYS",
        Integer.to_string(@default_retention_days)
      )
      |> String.to_integer()

    sweep(retention_days: days)
    schedule_sweep()
    {:noreply, state}
  end

  @doc """
  Remove files in `admin_queue/{completed,failed}/` older than
  `:retention_days` (default #{@default_retention_days}).

  Returns `:ok`. Intended for direct use by tests and for the
  self-scheduling `handle_info(:sweep, _)` tick.
  """
  def sweep(opts \\ []) do
    days = Keyword.get(opts, :retention_days, @default_retention_days)
    cutoff = System.system_time(:second) - days * 86_400

    for dir <- ["completed", "failed"] do
      path = Path.join(Esr.Paths.admin_queue_dir(), dir)
      sweep_dir(path, cutoff)
    end

    :ok
  end

  defp sweep_dir(path, cutoff) do
    case File.ls(path) do
      {:ok, files} ->
        for file <- files, do: maybe_remove(Path.join(path, file), cutoff)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("admin.janitor: ls #{path} failed: #{inspect(reason)}")
        :ok
    end
  end

  defp maybe_remove(full, cutoff) do
    case File.stat(full, time: :posix) do
      {:ok, %{mtime: mt}} when mt < cutoff ->
        case File.rm(full) do
          :ok ->
            Logger.debug("admin.janitor: removed #{full}")
            :ok

          {:error, reason} ->
            Logger.warning("admin.janitor: rm #{full} failed: #{inspect(reason)}")
            :ok
        end

      _ ->
        :ok
    end
  end

  defp schedule_sweep,
    do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end

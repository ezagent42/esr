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
       cast `{:execute, cmd, {:reply_to, {:file, completed_path}}}`
       to `Esr.Admin.Dispatcher`. On YAML parse failure, log and
       continue (moving the file to `failed/` is the Task 14/14b
       Dispatcher's responsibility).

  Dispatcher is started *before* Watcher by `Esr.Admin.Supervisor`
  (`:rest_for_one`, Dispatcher is first child), so the cast always
  lands on a live named process.
  """
  use GenServer
  require Logger

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    admin_dir = Esr.Paths.admin_queue_dir()
    pending_dir = Path.join(admin_dir, "pending")

    File.mkdir_p!(pending_dir)
    File.mkdir_p!(Path.join(admin_dir, "processing"))
    File.mkdir_p!(Path.join(admin_dir, "completed"))
    File.mkdir_p!(Path.join(admin_dir, "failed"))

    {:ok, pid} = FileSystem.start_link(dirs: [pending_dir])
    FileSystem.subscribe(pid)
    Logger.info("admin.watcher: watching #{pending_dir}")
    {:ok, %{fs_pid: pid, pending_dir: pending_dir}}
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

        case YamlElixir.read_from_file(path) do
          {:ok, cmd} ->
            GenServer.cast(
              Esr.Admin.Dispatcher,
              {:execute, cmd, {:reply_to, {:file, completed_path(basename)}}}
            )

          {:error, err} ->
            Logger.error("admin.watcher: bad yaml #{path}: #{inspect(err)}")
        end

        {:noreply, state}
    end
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}

  defp completed_path(basename),
    do: Path.join([Esr.Paths.admin_queue_dir(), "completed", basename])
end

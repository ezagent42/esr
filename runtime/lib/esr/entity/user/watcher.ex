defmodule Esr.Entity.User.Watcher do
  @moduledoc """
  Watches `users.yaml` and triggers `Esr.Entity.User.FileLoader.load/1` on
  any change event. Performs the initial load on start.

  Mirrors `Esr.Resource.Capability.Watcher` (same FSEvents-based pattern;
  same macOS basename-comparison quirk — the system rewrites paths
  through `/private/var` so we compare basenames rather than full
  paths).

  ## Watch-on-create (walkthrough-4 C5-A)

  Pre-fix, when `users.yaml` was absent at boot (clean-state `~/.esrd`,
  zero-config bootstrap), the watcher logged `will not watch` and
  permanently stopped listening. Subsequent file creation (the very
  next `user_add` writing the yaml) fired no events into the watcher,
  so any hot-reload of the URI store relied on the writer explicitly
  calling `FileLoader.load/1` — and operators who hand-edited the file
  with esrd already running got silently stale in-memory state.

  Fix: always subscribe to the **parent directory** (creating it if
  absent). FSEvents emits `:created` events when the yaml first lands;
  the same `handle_info/2` clause that handles `:modified` events
  triggers the reload via basename match.
  """

  @behaviour Esr.Role.Control
  use GenServer
  require Logger

  alias Esr.Entity.User.FileLoader

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    FileLoader.load(path)

    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    {:ok, pid} = FileSystem.start_link(dirs: [dir])
    FileSystem.subscribe(pid)

    if File.exists?(path) do
      Logger.info("users: watching #{dir} (loaded #{Path.basename(path)})")
    else
      Logger.info(
        "users: watching #{dir} for #{Path.basename(path)} creation (file absent at boot)"
      )
    end

    {:ok, %{path: path, fs_pid: pid}}
  end

  @impl true
  def handle_info({:file_event, _pid, {changed_path, _events}}, %{path: path} = state) do
    if Path.basename(changed_path) == Path.basename(path) do
      FileLoader.load(path)
    end

    {:noreply, state}
  end

  def handle_info({:file_event, _pid, :stop}, state) do
    {:noreply, state}
  end
end

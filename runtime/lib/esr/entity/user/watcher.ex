defmodule Esr.Entity.User.Watcher do
  @moduledoc """
  Watches `users.yaml` and triggers `Esr.Entity.User.FileLoader.load/1` on
  any change event. Performs the initial load on start.

  Mirrors `Esr.Resource.Capability.Watcher` (same FSEvents-based pattern;
  same macOS basename-comparison quirk — the system rewrites paths
  through `/private/var` so we compare basenames rather than full
  paths).
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

    case File.exists?(path) do
      true ->
        {:ok, pid} = FileSystem.start_link(dirs: [Path.dirname(path)])
        FileSystem.subscribe(pid)
        {:ok, %{path: path, fs_pid: pid}}

      false ->
        Logger.info("users: file not present at #{path}; will not watch")
        {:ok, %{path: path, fs_pid: nil}}
    end
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

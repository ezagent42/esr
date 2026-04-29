defmodule Esr.Capabilities.Watcher do
  @moduledoc """
  Watches the capabilities.yaml file and triggers FileLoader.load/1 on
  any change event. Also performs the initial load on start.
  """

  @behaviour Esr.Role.Control
  use GenServer
  require Logger

  alias Esr.Capabilities.FileLoader

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    # initial load
    FileLoader.load(path)

    case File.exists?(path) do
      true ->
        {:ok, pid} = FileSystem.start_link(dirs: [Path.dirname(path)])
        FileSystem.subscribe(pid)
        {:ok, %{path: path, fs_pid: pid}}

      false ->
        Logger.warning("capabilities: file not present at #{path}; will not watch")
        {:ok, %{path: path, fs_pid: nil}}
    end
  end

  @impl true
  def handle_info({:file_event, _pid, {changed_path, _events}}, %{path: path} = state) do
    # mac FSEvents emits paths under /private/var, while our tmp path lives
    # under /var (a symlink). Compare by basename since we watch exactly
    # one directory — that's unambiguous for our use.
    if Path.basename(changed_path) == Path.basename(path) do
      FileLoader.load(path)
    end

    {:noreply, state}
  end

  def handle_info({:file_event, _pid, :stop}, state) do
    {:noreply, state}
  end
end

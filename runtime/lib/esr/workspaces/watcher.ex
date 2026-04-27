defmodule Esr.Workspaces.Watcher do
  @moduledoc """
  Watches `workspaces.yaml` and reloads `Esr.Workspaces.Registry` on
  any change event. Modeled on `Esr.Capabilities.Watcher` (same
  fs_watch + reload pattern).

  PR-C 2026-04-27 actor-topology-routing §6.1 + §7. Runtime-time yaml
  edits used to require an esrd restart; this watcher closes that gap
  and emits `Phoenix.PubSub` notifications so active CC peers can
  react (eager-add neighbours into reachable_set; remove edges stay
  lazy until session_end per spec §7).

  Broadcast topic format follows the repo convention `<feature>:<id>`:

      "topology:events"          — global topology change signal
      "topology:<workspace>"     — per-workspace targeted updates

  Message shapes:

      {:topology_loaded, %{added_workspaces: [ws_name]}}
      {:topology_neighbour_added, ws_name, uri}
  """
  use GenServer
  require Logger

  alias Esr.Workspaces.Registry, as: WS

  @global_topic "topology:events"

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)

    # Initial load — populate registry before announcing readiness.
    prior_closure = capture_closure()
    :ok = reload(path)
    announce_diff(prior_closure)

    case File.exists?(path) do
      true ->
        {:ok, fs_pid} = FileSystem.start_link(dirs: [Path.dirname(path)])
        FileSystem.subscribe(fs_pid)
        {:ok, %{path: path, fs_pid: fs_pid}}

      false ->
        Logger.warning("workspaces: file not present at #{path}; will not watch")
        {:ok, %{path: path, fs_pid: nil}}
    end
  end

  @impl true
  def handle_info({:file_event, _pid, {changed_path, _events}}, %{path: path} = state) do
    if Path.basename(changed_path) == Path.basename(path) do
      prior_closure = capture_closure()

      case reload(path) do
        :ok ->
          announce_diff(prior_closure)

        {:error, reason} ->
          Logger.error("workspaces: reload failed; keeping previous snapshot. reason=#{inspect(reason)}")
      end
    end

    {:noreply, state}
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # internals
  # ------------------------------------------------------------------

  defp reload(path) do
    case WS.load_from_file(path) do
      {:ok, workspaces} ->
        Enum.each(workspaces, fn {_name, ws} -> WS.put(ws) end)

        # Drop any registered ws not in the new yaml — keeps in-memory
        # state aligned with disk on edits/removals.
        new_names = workspaces |> Map.keys() |> MapSet.new()

        for ws <- WS.list(), not MapSet.member?(new_names, ws.name) do
          :ets.delete(:esr_workspaces, ws.name)
        end

        :ok

      {:error, _} = err ->
        err
    end
  end

  defp capture_closure do
    Esr.Topology.symmetric_closure()
  rescue
    _ -> %{}
  end

  defp announce_diff(prior_closure) do
    new_closure = capture_closure()

    # Eager-add: for every workspace that has new URIs in its
    # neighbour set, broadcast a per-URI add event so CC peers
    # subscribed to that workspace can grow their reachable_set.
    # Lazy-remove (spec §7): we don't broadcast removals — the cap
    # gate handles that at send time.
    for {ws, new_uris} <- new_closure do
      old = Map.get(prior_closure, ws, MapSet.new())
      added = MapSet.difference(new_uris, old)

      for uri <- added do
        broadcast({:topology_neighbour_added, ws, uri}, ws)
      end
    end

    broadcast({:topology_loaded, %{}}, :global)
  end

  defp broadcast(msg, :global) do
    if Process.whereis(EsrWeb.PubSub) do
      Phoenix.PubSub.broadcast(EsrWeb.PubSub, @global_topic, msg)
    end
  end

  defp broadcast(msg, ws) when is_binary(ws) do
    if Process.whereis(EsrWeb.PubSub) do
      Phoenix.PubSub.broadcast(EsrWeb.PubSub, "topology:" <> ws, msg)
      Phoenix.PubSub.broadcast(EsrWeb.PubSub, @global_topic, msg)
    end
  end
end

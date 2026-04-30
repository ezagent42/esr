defmodule Esr.SlashRoutes.Watcher do
  @moduledoc """
  Watches `slash-routes.yaml` and triggers `FileLoader.load/1` on change.
  Performs initial load on start; bootstraps from `priv/slash-routes.default.yaml`
  if the runtime file is absent (PR-21κ).

  Mirrors `Esr.Capabilities.Watcher` shape — see
  `docs/notes/yaml-authoring-lessons.md` for the canonical 4-piece pattern.
  """

  @behaviour Esr.Role.Control
  use GenServer
  require Logger

  alias Esr.SlashRoutes.FileLoader

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)

    # PR-21κ priv-seed: if no operator-managed yaml exists yet, copy
    # the default template shipped in priv/. Documents the seed pattern
    # for future yaml-driven subsystems (see yaml-authoring-lessons.md).
    maybe_seed_default(path)

    FileLoader.load(path)

    case File.exists?(path) do
      true ->
        {:ok, fs_pid} = FileSystem.start_link(dirs: [Path.dirname(path)])
        FileSystem.subscribe(fs_pid)
        {:ok, %{path: path, fs_pid: fs_pid}}

      false ->
        Logger.warning("slash_routes: file not present at #{path}; will not watch")
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

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp maybe_seed_default(target_path) do
    if not File.exists?(target_path) do
      src = Application.app_dir(:esr, "priv/slash-routes.default.yaml")

      cond do
        not File.exists?(src) ->
          Logger.warning(
            "slash_routes: priv default at #{src} missing; runtime file will be empty until operator creates it"
          )

        true ->
          File.mkdir_p!(Path.dirname(target_path))

          case File.cp(src, target_path) do
            :ok ->
              Logger.info("slash_routes: seeded #{target_path} from priv default")

            {:error, reason} ->
              Logger.warning(
                "slash_routes: priv-seed copy failed (#{inspect(reason)}); operator must create #{target_path} manually"
              )
          end
      end
    end
  end
end

defmodule Esr.Workers.AdapterProcess do
  @moduledoc """
  Per-adapter Python sidecar managed by `:erlexec` (PR-21β, 2026-04-30).

  Replaces the bash `& disown` + pidfile path that the legacy
  `Esr.WorkerSupervisor.spawn_python/1` used. Lifecycle is BEAM-bound:
  when the BEAM exits (clean stop, hard crash, or `kill -9`), erlexec's
  C++ port program SIGKILLs the child. Zero orphan accumulation.

  Direct `<repo>/py/.venv/bin/python -m <sidecar_module>` invocation
  bypasses `uv run` so erlexec tracks the actual Python pid (the
  pre-PR-21β bug recorded the `uv` wrapper pid which exited after
  exec, making the real adapter invisible to all kill / scan logic).

  Uses `wrapper: :plain` (no PTY) — Python adapter sidecars line-buffer
  their own stdout via `PYTHONUNBUFFERED=1`.

  See `docs/superpowers/specs/2026-04-30-esrd-worker-lifecycle-design.md`.
  """

  @behaviour Esr.Role.Boundary

  use Esr.Peer.Stateful
  use Esr.OSProcess, kind: :adapter, wrapper: :plain

  require Logger

  def start_link(%{adapter: _, instance_id: _, url: _, config_json: _} = args) do
    GenServer.start_link(__MODULE__.OSProcessWorker, args)
  end

  # Required by DynamicSupervisor (the OSProcess macro defines an
  # OSProcessWorker module but doesn't expose a top-level child_spec
  # for us). Default `:transient` restart so a normal exit (status=0)
  # doesn't trigger respawn but a crash (non-zero) does.
  def child_spec(args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args]},
      restart: :transient,
      type: :worker,
      shutdown: 10_000
    }
  end

  @impl Esr.OSProcess
  def os_cmd(state) do
    [
      python_bin(),
      "-m",
      Esr.WorkerSupervisor.sidecar_module(state.adapter),
      "--adapter",
      state.adapter,
      "--instance-id",
      state.instance_id,
      "--url",
      state.url,
      "--config-json",
      state.config_json
    ]
  end

  @impl Esr.OSProcess
  def os_env(_state) do
    [
      {"ESR_SPAWN_TOKEN", Application.get_env(:esr, :spawn_token, "")},
      {"PYTHONUNBUFFERED", "1"}
    ]
  end

  @impl Esr.OSProcess
  def os_cwd(_state), do: py_project_dir()

  @impl Esr.OSProcess
  def on_os_exit(0, _state), do: {:stop, :normal}
  def on_os_exit(status, _state), do: {:stop, {:py_crashed, status}}

  # Called by the generated OSProcessWorker.init/1 (not a GenServer
  # callback — the worker module uses GenServer; this module passes
  # through the args as the initial peer state).
  def init(args), do: {:ok, args}

  @impl Esr.Peer.Stateful
  def handle_upstream({:os_stdout, line}, state) do
    Logger.info("[adapter #{state.adapter}/#{state.instance_id}] #{line}")
    {:forward, [], state}
  end

  def handle_upstream({:os_stderr, line}, state) do
    Logger.warning("[adapter #{state.adapter}/#{state.instance_id}] #{line}")
    {:forward, [], state}
  end

  def handle_upstream(_msg, state), do: {:forward, [], state}

  @impl Esr.Peer.Stateful
  def handle_downstream(_msg, state), do: {:forward, [], state}

  defp python_bin do
    Path.join(py_project_dir(), ".venv/bin/python")
  end

  defp py_project_dir do
    case Application.get_env(:esr, :py_project_dir) do
      path when is_binary(path) ->
        path

      _ ->
        try do
          app = Application.app_dir(:esr)
          repo = app |> Path.split() |> Enum.reverse() |> Enum.drop(4) |> Enum.reverse() |> Path.join()
          candidate = Path.join(repo, "py")
          if File.dir?(candidate), do: candidate, else: Path.expand("../py", File.cwd!())
        rescue
          _ -> Path.expand("../py", File.cwd!())
        end
    end
  end
end

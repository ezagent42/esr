defmodule Esr.Workers.HandlerProcess do
  @moduledoc """
  Per-handler Python worker managed by `:erlexec` (PR-21β, 2026-04-30).

  Symmetric to `Esr.Workers.AdapterProcess`. Spawns
  `python -m esr.ipc.handler_worker --module <mod> --worker-id <id>
  --url <url>`. Same lifecycle / stdout-routing / token-injection
  semantics.

  See `docs/superpowers/specs/2026-04-30-esrd-worker-lifecycle-design.md`.
  """

  @behaviour Esr.Role.Boundary

  use Esr.Entity.Stateful
  use Esr.OSProcess, kind: :handler, wrapper: :plain

  require Logger

  def start_link(%{module: _, worker_id: _, url: _} = args) do
    GenServer.start_link(__MODULE__.OSProcessWorker, args)
  end

  def child_spec(args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args]},
      restart: :transient,
      type: :worker,
      shutdown: 5_000
    }
  end

  @impl Esr.OSProcess
  def os_cmd(state) do
    [
      python_bin(),
      "-m",
      "esr.ipc.handler_worker",
      "--module",
      state.module,
      "--worker-id",
      state.worker_id,
      "--url",
      state.url
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

  def init(args), do: {:ok, args}

  @impl Esr.Entity.Stateful
  def handle_upstream({:os_stdout, line}, state) do
    Logger.info("[handler #{state.module}/#{state.worker_id}] #{line}")
    {:forward, [], state}
  end

  def handle_upstream({:os_stderr, line}, state) do
    Logger.warning("[handler #{state.module}/#{state.worker_id}] #{line}")
    {:forward, [], state}
  end

  def handle_upstream(_msg, state), do: {:forward, [], state}

  @impl Esr.Entity.Stateful
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

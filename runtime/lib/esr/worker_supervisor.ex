defmodule Esr.WorkerSupervisor do
  @moduledoc """
  Spawns and tracks Python adapter/handler subprocesses (Phase 8f).

  When Topology.Instantiator binds an adapter or starts a PeerServer,
  the Python-side counterpart (the per-type adapter sidecars —
  ``feishu_adapter_runner``, ``cc_adapter_runner``,
  ``generic_adapter_runner`` — and ``esr.ipc.handler_worker``) must be
  joined to the matching Phoenix channel *before* the first
  directive/call broadcasts. `scripts/
  spawn_scenario_workers.sh` pre-spawns these externally for the mock
  scenario, but `final_gate.sh --live` is SHA-pinned and can't take
  that extra step — so the runtime launches them itself, on demand,
  keyed by (adapter_name, instance_id) or (module, worker_id).

  ## Idempotency

  `ensure_adapter/4` and `ensure_handler/3` are both idempotent:

    * If this supervisor already spawned a live Python process for
      that key, returns `:already_running` without touching the shell.
    * If the external fixture (spawn_scenario_workers.sh) spawned a
      worker under `/tmp/esr-worker-<slug>.pid`, the pidfile check
      here will see the live pid and skip re-spawning.

  ## Shutdown

  On supervisor termination the GenServer kills every tracked pid
  with SIGTERM (then SIGKILL after 2 s). The pidfile directory is not
  cleaned — operators can still see what ran.
  """

  use GenServer

  require Logger

  @pidfile_dir "/tmp"

  # PR-4b: per-adapter-type sidecar dispatch. Adapters we ship own code
  # for get a dedicated Python module so their dependency footprint stays
  # scoped; anything not in the map falls through to generic_adapter_runner
  # (which emits a DeprecationWarning on stderr at startup so operators
  # know to add the adapter to a dedicated sidecar's allowlist).
  @sidecar_dispatch %{
    "feishu" => "feishu_adapter_runner",
    "cc_tmux" => "cc_adapter_runner",
    "cc_mcp" => "cc_adapter_runner"
  }

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @doc """
  Map an adapter name to the Python module that should host its sidecar.

  Known adapters route to dedicated sidecars (e.g. `feishu_adapter_runner`,
  `cc_adapter_runner`). Unknown names fall back to `generic_adapter_runner`,
  which is a migration shim that prints a DeprecationWarning — add new
  adapters to a dedicated sidecar's allowlist instead of relying on the
  generic fallback.
  """
  @spec sidecar_module(String.t()) :: String.t()
  def sidecar_module(name) when is_binary(name),
    do: Map.get(@sidecar_dispatch, name, "generic_adapter_runner")

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensure a Python adapter sidecar subprocess is joined for
  `(adapter_name, instance_id)` against `url`.

  `config` is a map (or JSON-encoded string) passed verbatim to
  the sidecar CLI (`python -m <sidecar_module> --config-json ...`).
  `sidecar_module/1` picks the per-adapter module name.
  """
  @spec ensure_adapter(String.t(), String.t(), map() | String.t(), String.t()) ::
          :ok | :already_running | {:error, term()}
  def ensure_adapter(adapter_name, instance_id, config, url)
      when is_binary(adapter_name) and is_binary(instance_id) and
             (is_map(config) or is_binary(config)) and is_binary(url) do
    GenServer.call(
      __MODULE__,
      {:ensure_adapter, adapter_name, instance_id, config, url}
    )
  end

  @doc """
  Ensure a Python handler_worker subprocess is joined for
  `(handler_module, worker_id)` against `url`.
  """
  @spec ensure_handler(String.t(), String.t(), String.t()) ::
          :ok | :already_running | {:error, term()}
  def ensure_handler(handler_module, worker_id, url)
      when is_binary(handler_module) and is_binary(worker_id) and is_binary(url) do
    GenServer.call(
      __MODULE__,
      {:ensure_handler, handler_module, worker_id, url}
    )
  end

  @doc "List every (kind, name, id, pid) tuple currently tracked."
  @spec list() :: [{:adapter | :handler, String.t(), String.t(), integer()}]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Stop the Python adapter sidecar for `(adapter_name, instance_id)` and
  forget it. PR-L: counterpart to `ensure_adapter/4` so
  `cli:adapters/remove` can clean up the OS process. Idempotent — a
  no-op when the worker isn't tracked.
  """
  @spec terminate_adapter(String.t(), String.t()) :: :ok | :not_found
  def terminate_adapter(adapter_name, instance_id)
      when is_binary(adapter_name) and is_binary(instance_id) do
    GenServer.call(__MODULE__, {:terminate, {:adapter, adapter_name, instance_id}})
  end

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{workers: %{}}}
  end

  @impl GenServer
  def handle_call(
        {:ensure_adapter, adapter_name, instance_id, config, url},
        _from,
        state
      ) do
    key = {:adapter, adapter_name, instance_id}
    cfg_json = normalise_config(config)

    {reply, new_state} =
      ensure(
        state,
        key,
        pidfile_path(key),
        fn ->
          spawn_python([
            "-m",
            sidecar_module(adapter_name),
            "--adapter",
            adapter_name,
            "--instance-id",
            instance_id,
            "--url",
            url,
            "--config-json",
            cfg_json
          ])
        end
      )

    {:reply, reply, new_state}
  end

  def handle_call(
        {:ensure_handler, handler_module, worker_id, url},
        _from,
        state
      ) do
    key = {:handler, handler_module, worker_id}

    {reply, new_state} =
      ensure(
        state,
        key,
        pidfile_path(key),
        fn ->
          spawn_python([
            "-m",
            "esr.ipc.handler_worker",
            "--module",
            handler_module,
            "--worker-id",
            worker_id,
            "--url",
            url
          ])
        end
      )

    {:reply, reply, new_state}
  end

  def handle_call({:terminate, key}, _from, state) do
    case Map.get(state.workers, key) do
      nil ->
        {:reply, :not_found, state}

      %{pid: pid} = worker ->
        kill_pid(pid)
        # Best-effort pidfile cleanup so a future ensure_adapter doesn't
        # see a dead pid and assume the worker is external/already-up.
        case worker do
          %{pidfile: pf} when is_binary(pf) -> _ = File.rm(pf)
          _ -> :ok
        end

        new_workers = Map.delete(state.workers, key)
        {:reply, :ok, %{state | workers: new_workers}}
    end
  end

  def handle_call(:list, _from, state) do
    list =
      for {{kind, name, id}, %{pid: pid}} <- state.workers do
        {kind, name, id, pid}
      end

    {:reply, list, state}
  end

  @impl GenServer
  def handle_info({:EXIT, _port, _reason}, state) do
    # System.cmd under :trap_exit sends EXIT signals from its short-lived
    # Port back to us. They correspond to completed `kill -0` / `kill`
    # probes, not to tracked Python workers (those aren't linked to us —
    # they're detached via setsid). Swallow.
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    for {_key, %{pid: pid}} <- state.workers do
      kill_pid(pid)
    end

    :ok
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp ensure(state, key, pidfile, spawn_fn) do
    cond do
      tracked_alive?(state, key) ->
        {:already_running, state}

      external_alive?(pidfile) ->
        {:already_running, record_external(state, key, pidfile)}

      true ->
        case spawn_fn.() do
          {:ok, pid} ->
            File.write(pidfile, Integer.to_string(pid))
            {:ok, put_in(state.workers[key], %{pid: pid, pidfile: pidfile})}

          {:error, reason} ->
            Logger.warning("WorkerSupervisor spawn failed for #{inspect(key)}: #{inspect(reason)}")
            {{:error, reason}, state}
        end
    end
  end

  defp tracked_alive?(state, key) do
    case Map.get(state.workers, key) do
      %{pid: pid} -> pid_alive?(pid)
      nil -> false
    end
  end

  defp external_alive?(pidfile) do
    case File.read(pidfile) do
      {:ok, pid_s} ->
        case Integer.parse(String.trim(pid_s)) do
          {pid, _} -> pid_alive?(pid)
          :error -> false
        end

      {:error, _} ->
        false
    end
  end

  defp record_external(state, key, pidfile) do
    {:ok, pid_s} = File.read(pidfile)
    {pid, _} = Integer.parse(String.trim(pid_s))
    put_in(state.workers[key], %{pid: pid, pidfile: pidfile, external: true})
  end

  defp pid_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp pid_alive?(_), do: false

  defp pidfile_path({:adapter, name, id}) do
    slug = "adapter-" <> name <> "-" <> slugify(id)
    Path.join(@pidfile_dir, "esr-worker-" <> slug <> ".pid")
  end

  defp pidfile_path({:handler, module, worker_id}) do
    slug = "handler-" <> slugify(module) <> "-" <> slugify(worker_id)
    Path.join(@pidfile_dir, "esr-worker-" <> slug <> ".pid")
  end

  defp slugify(s) do
    s
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
  end

  defp normalise_config(cfg) when is_binary(cfg), do: cfg
  defp normalise_config(cfg) when is_map(cfg), do: Jason.encode!(cfg)

  # Spawn `uv run --project py python <args>` detached from our stdio
  # with output redirected to /tmp/esr-worker-<slug>.log. Returns the
  # OS pid of the Python process (best-effort; uv forks so the captured
  # pid may be uv's — good enough for liveness checks).
  defp spawn_python(extra_args) do
    repo = repo_root()
    log_path = log_path_for(extra_args)
    # scripts/spawn_worker.sh daemonises the process and prints its pid —
    # solves the bash-in-bash-in-elixir stdin/stdout-inheritance hang the
    # inline `cmd & echo $!` invocation triggered on macOS.
    wrapper = Path.join(repo, "scripts/spawn_worker.sh")
    argv = [wrapper, log_path, "uv", "run", "--project", "py", "python"] ++ extra_args

    case System.cmd(hd(argv), tl(argv), cd: repo, stderr_to_stdout: false) do
      {out, 0} ->
        case out |> String.trim() |> Integer.parse() do
          {pid, _} when pid > 0 -> {:ok, pid}
          _ -> {:error, {:spawn_bad_output, out}}
        end

      {out, code} ->
        {:error, {:spawn_failed, code, out}}
    end
  end

  defp repo_root do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {path, 0} -> String.trim(path)
      _ -> File.cwd!()
    end
  end

  defp log_path_for(args) do
    # Mirror the pidfile naming so operators can cross-reference. The
    # module in argv is one of the three per-type sidecars:
    # `{feishu,cc,generic}_adapter_runner`.
    case args do
      ["-m", module, "--adapter", name, "--instance-id", id | _]
      when module in [
             "feishu_adapter_runner",
             "cc_adapter_runner",
             "generic_adapter_runner"
           ] ->
        Path.join(@pidfile_dir, "esr-worker-adapter-" <> name <> "-" <> slugify(id) <> ".log")

      ["-m", "esr.ipc.handler_worker", "--module", module, "--worker-id", wid | _] ->
        Path.join(
          @pidfile_dir,
          "esr-worker-handler-" <> slugify(module) <> "-" <> slugify(wid) <> ".log"
        )

      _ ->
        Path.join(@pidfile_dir, "esr-worker-unknown.log")
    end
  end

  defp kill_pid(pid) do
    _ = System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    :timer.sleep(500)
    _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
  end
end

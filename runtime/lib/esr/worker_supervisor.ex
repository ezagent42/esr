defmodule Esr.WorkerSupervisor do
  @moduledoc """
  Tracks Python adapter/handler subprocesses spawned via `:erlexec`
  through the `Esr.Workers.{AdapterProcess,HandlerProcess}` peer
  modules (PR-21β, 2026-04-30).

  Replaces the pre-PR-21β `bash & disown` + pidfile + `cleanup_orphans`
  apparatus. BEAM owns subprocess lifecycle: when esrd exits, every
  worker dies with it (handled by the erlexec C++ port program).
  Zero pidfiles, zero orphan-management, zero on-disk state.

  ## Idempotency

  `ensure_adapter/4` and `ensure_handler/3` are both idempotent:

    * If a child for this `(adapter, instance_id)` / `(module, worker_id)`
      key is already alive, returns `:already_running`.
    * Otherwise spawns a new child under the internal DynamicSupervisor.

  ## Crash policy

  The internal DynamicSupervisor has `max_restarts: 3, max_seconds: 60`.
  A child that exits non-zero is restarted (`:transient` semantics).
  Budget exhaustion (4 crashes within 60s) takes down the
  WorkerSupervisor itself, escalating to esrd shutdown — launchd
  respawns the whole tree, which is the correct response to a
  systemic problem.

  ## Sidecar dispatch

  `sidecar_module/1` maps an adapter name to the Python module that
  hosts its sidecar (e.g. `"feishu" → "feishu_adapter_runner"`).
  Unknown names fall back to `generic_adapter_runner`.
  """

  @behaviour Esr.Role.OTP

  use GenServer
  require Logger

  # Per-adapter-type sidecar dispatch. Adapters we ship own code for get
  # a dedicated Python module so their dependency footprint stays scoped;
  # anything not in the map falls through to generic_adapter_runner
  # (which emits a DeprecationWarning on stderr at startup).
  @sidecar_dispatch %{
    "feishu" => "feishu_adapter_runner",
    "cc_mcp" => "cc_adapter_runner"
  }

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @doc """
  Map an adapter name to the Python module that should host its sidecar.

  Known adapters route to dedicated sidecars; unknown names fall back
  to `generic_adapter_runner`.
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

  Returns `:ok` on fresh spawn, `:already_running` if a live child for
  the key exists, or `{:error, reason}` if the DynamicSupervisor
  rejected the spawn.
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
  @spec list() :: [{:adapter | :handler, String.t(), String.t(), pid()}]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Stop the worker for `(adapter_name, instance_id)` and forget it.
  Idempotent — `:not_found` when no live child exists for the key.
  """
  @spec terminate_adapter(String.t(), String.t()) :: :ok | :not_found
  def terminate_adapter(adapter_name, instance_id)
      when is_binary(adapter_name) and is_binary(instance_id) do
    GenServer.call(__MODULE__, {:terminate, {:adapter, adapter_name, instance_id}})
  end

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    {:ok, sup} =
      DynamicSupervisor.start_link(
        strategy: :one_for_one,
        max_restarts: 3,
        max_seconds: 60
      )

    # workers: %{ {:adapter | :handler, name, id} => pid }
    {:ok, %{sup: sup, workers: %{}}}
  end

  @impl true
  def handle_call(
        {:ensure_adapter, adapter_name, instance_id, config, url},
        _from,
        state
      ) do
    key = {:adapter, adapter_name, instance_id}
    cfg_json = normalise_config(config)

    args = %{
      adapter: adapter_name,
      instance_id: instance_id,
      url: url,
      config_json: cfg_json
    }

    spawn_or_already(state, key, {Esr.Workers.AdapterProcess, args})
  end

  def handle_call(
        {:ensure_handler, handler_module, worker_id, url},
        _from,
        state
      ) do
    key = {:handler, handler_module, worker_id}

    args = %{
      module: handler_module,
      worker_id: worker_id,
      url: url
    }

    spawn_or_already(state, key, {Esr.Workers.HandlerProcess, args})
  end

  def handle_call({:terminate, key}, _from, state) do
    case Map.get(state.workers, key) do
      pid when is_pid(pid) ->
        _ = DynamicSupervisor.terminate_child(state.sup, pid)
        {:reply, :ok, %{state | workers: Map.delete(state.workers, key)}}

      nil ->
        {:reply, :not_found, state}
    end
  end

  def handle_call(:list, _from, state) do
    list =
      for {{kind, name, id}, pid} <- state.workers do
        {kind, name, id, pid}
      end

    {:reply, list, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Worker died; DynamicSupervisor will restart it under :transient
    # semantics if exit was abnormal. Drop the stale pid from our
    # index — the next ensure_* call will re-spawn or pick up the
    # restarted child via DynamicSupervisor's own bookkeeping.
    workers = for {k, p} <- state.workers, p != pid, into: %{}, do: {k, p}
    {:noreply, %{state | workers: workers}}
  end

  def handle_info({:EXIT, _from, _reason}, state) do
    # Trapped exits from the linked DynamicSupervisor are handled by
    # standard supervisor crash semantics (we crash too). Other linked
    # exits (none expected) are swallowed.
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # DynamicSupervisor.terminate_child cascades: each child's
    # OSProcessWorker.terminate/2 calls :exec.stop/1 which SIGTERMs
    # then SIGKILLs after kill_timeout. All workers gone before BEAM
    # exits.
    if Process.alive?(state.sup), do: Process.exit(state.sup, :shutdown)
    :ok
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp spawn_or_already(state, key, child_spec) do
    case Map.get(state.workers, key) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          {:reply, :already_running, state}
        else
          spawn_and_track(state, key, child_spec)
        end

      nil ->
        spawn_and_track(state, key, child_spec)
    end
  end

  defp spawn_and_track(state, key, child_spec) do
    case DynamicSupervisor.start_child(state.sup, child_spec) do
      {:ok, pid} ->
        Process.monitor(pid)
        {:reply, :ok, %{state | workers: Map.put(state.workers, key, pid)}}

      {:error, {:already_started, pid}} ->
        Process.monitor(pid)
        {:reply, :already_running, %{state | workers: Map.put(state.workers, key, pid)}}

      {:error, reason} ->
        Logger.warning(
          "WorkerSupervisor spawn failed key=#{inspect(key)} reason=#{inspect(reason)}"
        )

        {:reply, {:error, reason}, state}
    end
  end

  defp normalise_config(cfg) when is_binary(cfg), do: cfg
  defp normalise_config(cfg) when is_map(cfg), do: Jason.encode!(cfg)
end

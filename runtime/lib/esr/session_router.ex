defmodule Esr.SessionRouter do
  @moduledoc """
  Control-plane coordinator for Session lifecycle.

  Accepts only control-plane events:
    * `:create_session_sync`   — from `Esr.Admin.Commands.Session.New`
    * `:end_session_sync`      — from `Esr.Admin.Commands.Session.End`
    * `:new_chat_thread`       — PubSub broadcast from `FeishuAppAdapter`
                                 on `lookup_by_chat_thread → :not_found`
    * `:peer_crashed`          — internal, raised by `Process.monitor`
                                 DOWNs on spawned peer pids
    * `:agents_yaml_reloaded`  — from `SessionRegistry` watcher (stub;
                                 handled by a no-op `handle_info` clause
                                 in PR-3)

  Spec §3.3 (control-plane trinity), §6 Risk E (data-plane boundary).

  ## Risk E — data-plane boundary

  The data-plane hot path (inbound/outbound user-message traffic) must
  **not** pass through this GenServer. `handle_call/3` rejects any
  unexpected shape with `{:error, :not_control_plane}` and a WARN log;
  `handle_info/2` drops unexpected shapes with a WARN and stays alive.
  Tests in `session_router_test.exs` assert this contract.

  ## Drift from expansion doc (§ P3-4.2)

  * The expansion's `spawn_pipeline` iterates `inbound ++ proxies` and
    calls `PeerFactory.spawn_peer/5` for every element. In the current
    codebase, `Peer.Proxy` modules (e.g. `Esr.Peers.CCProxy`,
    `Esr.Peers.FeishuAppProxy`) are **stateless forwarder modules** —
    they have no `start_link/1` / `init/1` and cannot be hosted by a
    `DynamicSupervisor`. The router here only spawns peers whose
    `peer_kind/0` is `:stateful`; proxy entries are recorded in the
    refs map as `{:proxy_module, Module}` so downstream wiring can
    still resolve them symbolically.

  * `build_ctx` for `CCProxy` is a no-op here: the `cc_process_pid`
    injection that the expansion calls out in the CCProxy `@moduledoc`
    is a **future-hook** (PR-4+). Today's CCProxy is a stateless
    module; ctx is only relevant when `forward/2` is invoked.

  * Wiring into `Esr.Application` children is **deferred**. The router
    is not a child of `Esr.Supervisor` in PR-3 scope; tests
    `start_supervised!(Esr.SessionRouter)` it directly. `Session.New`
    still goes through `SessionsSupervisor.start_session/1` (legacy
    path) until a follow-up subtask rewires it.
  """
  use GenServer
  require Logger

  @stateful_impls MapSet.new([
                    "Esr.Peers.FeishuChatProxy",
                    "Esr.Peers.CCProcess",
                    "Esr.Peers.TmuxProcess",
                    "Esr.Peers.FeishuAppAdapter"
                  ])

  # ------------------------------------------------------------------
  # Public API — both paths go through a GenServer.call for backpressure.
  # ------------------------------------------------------------------

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec create_session(map()) :: {:ok, String.t()} | {:error, term()}
  def create_session(params),
    do: GenServer.call(__MODULE__, {:create_session_sync, params}, 30_000)

  @spec end_session(String.t()) :: :ok | {:error, term()}
  def end_session(session_id),
    do: GenServer.call(__MODULE__, {:end_session_sync, session_id}, 10_000)

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl true
  def init(_) do
    _ = subscribe_to_new_chat_thread()
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:create_session_sync, params}, _from, state) do
    case do_create(params) do
      {:ok, sid, monitor_refs} ->
        monitors =
          Enum.reduce(monitor_refs, state.monitors, fn {ref, pid}, acc ->
            Map.put(acc, ref, {sid, pid})
          end)

        {:reply, {:ok, sid}, %{state | monitors: monitors}}

      {:error, _reason} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:end_session_sync, sid}, _from, state) do
    via = {:via, Registry, {Esr.Session.Registry, {:session_sup, sid}}}

    case GenServer.whereis(via) do
      nil ->
        {:reply, {:error, :unknown_session}, state}

      pid when is_pid(pid) ->
        :ok = Esr.SessionsSupervisor.stop_session(pid)
        :ok = Esr.SessionRegistry.unregister_session(sid)
        {:reply, :ok, state}
    end
  end

  # Risk E: reject anything shaped like data-plane via call.
  def handle_call(unexpected, _from, state) do
    Logger.warning(
      "SessionRouter: rejected unexpected call #{inspect(unexpected)} (Risk E boundary)"
    )

    {:reply, {:error, :not_control_plane}, state}
  end

  @impl true
  def handle_info({:new_chat_thread, chat_id, thread_id, app_id, envelope}, state) do
    # PR-3: log the signal but do not auto-create. Slash-initiated flow
    # is the only session-creation path in PR-3 scope.
    :telemetry.execute(
      [:esr, :session_router, :new_chat_thread_dropped],
      %{count: 1},
      %{chat_id: chat_id, thread_id: thread_id, app_id: app_id}
    )

    Logger.info(
      "session_router: observed new_chat_thread chat_id=#{inspect(chat_id)} " <>
        "thread_id=#{inspect(thread_id)} (PR-3 no-auto-create; use /new-session slash)"
    )

    _ = envelope
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {{sid, _peer_pid}, rest} ->
        :telemetry.execute(
          [:esr, :session_router, :peer_crashed],
          %{count: 1},
          %{session_id: sid, reason: inspect(reason)}
        )

        # PR-3 policy: peer crash inside a session — the Session's
        # :one_for_all supervisor already tears the subtree down. We
        # observe, we don't rebuild. PR-4+ may add rebuild logic.
        {:noreply, %{state | monitors: rest}}
    end
  end

  # Stub clause for the yaml-reload watcher that will land in a later PR.
  def handle_info(:agents_yaml_reloaded, state), do: {:noreply, state}

  # Risk E: anything else is dropped with a WARN rather than crashing.
  def handle_info(msg, state) do
    Logger.warning(
      "SessionRouter: dropped unexpected info #{inspect(msg)} (Risk E boundary)"
    )

    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp subscribe_to_new_chat_thread do
    # Only subscribe if the PubSub is running. In isolated unit tests
    # that don't boot `EsrWeb.PubSub`, skipping the subscribe keeps
    # `init/1` from crashing the test supervisor.
    case Process.whereis(EsrWeb.PubSub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.subscribe(EsrWeb.PubSub, "new_chat_thread")
    end
  end

  defp do_create(params) do
    with {:ok, agent_name} <- fetch_agent_name(params),
         {:ok, agent_def} <- fetch_agent(agent_name),
         session_id <- gen_id(),
         {:ok, _sup} <- start_session_sup(session_id, agent_name, params, agent_def),
         {:ok, refs_map, mon} <- spawn_pipeline(session_id, agent_def, params),
         :ok <- register(session_id, params, refs_map) do
      {:ok, session_id, mon}
    end
  end

  defp fetch_agent_name(params) do
    case params[:agent] || params["agent"] do
      nil -> {:error, :agent_required}
      name when is_binary(name) -> {:ok, name}
    end
  end

  defp fetch_agent(name) do
    case Esr.SessionRegistry.agent_def(name) do
      {:ok, d} -> {:ok, d}
      {:error, :not_found} -> {:error, :unknown_agent}
    end
  end

  # ULID-ish — 96 bits encoded base32 (no padding). Good enough for
  # session identity; callers get an opaque binary id.
  defp gen_id, do: :crypto.strong_rand_bytes(12) |> Base.encode32(padding: false)

  defp start_session_sup(sid, agent_name, params, agent_def) do
    chat_id = get_param(params, :chat_id) || ""
    thread_id = get_param(params, :thread_id) || ""
    principal_id = get_param(params, :principal_id)
    dir = get_param(params, :dir)

    Esr.SessionsSupervisor.start_session(%{
      session_id: sid,
      agent_name: agent_name,
      dir: dir,
      chat_thread_key: %{chat_id: chat_id, thread_id: thread_id},
      metadata: %{principal_id: principal_id, agent_def: agent_def}
    })
  end

  # Spawn every Stateful peer in inbound order; record Proxy modules
  # symbolically without spawning. Monitor each spawned pid so DOWNs
  # feed back into handle_info/2's peer_crashed telemetry.
  defp spawn_pipeline(session_id, agent_def, params) do
    inbound = agent_def.pipeline.inbound || []
    proxies = agent_def.proxies || []

    try do
      {refs, monitors} =
        Enum.reduce(inbound, {%{}, []}, fn spec, {refs_acc, mon_acc} ->
          spawn_one(session_id, spec, params, refs_acc, mon_acc)
        end)

      # Proxies are stateless modules — no pid, no monitor. Record
      # them so `lookup_by_chat_thread/2` can surface the wiring for
      # callers that need to know "which Proxy module forwards where."
      refs =
        Enum.reduce(proxies, refs, fn spec, acc ->
          name = String.to_atom(spec["name"])
          impl = resolve_impl(spec["impl"])
          Map.put(acc, name, {:proxy_module, impl})
        end)

      {:ok, refs, monitors}
    catch
      {:spawn_failed, spec, reason} ->
        {:error, {:peer_spawn_failed, spec, reason}}
    end
  end

  defp spawn_one(session_id, spec, params, refs_acc, mon_acc) do
    name = String.to_atom(spec["name"])
    impl_str = spec["impl"] || ""

    if MapSet.member?(@stateful_impls, impl_str) do
      impl = resolve_impl(impl_str)
      neighbors = build_neighbors(refs_acc)
      ctx = build_ctx(spec, params)
      args = spawn_args(spec, params)

      case Esr.PeerFactory.spawn_peer(session_id, impl, args, neighbors, ctx) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          {Map.put(refs_acc, name, pid), [{ref, pid} | mon_acc]}

        {:error, reason} ->
          throw({:spawn_failed, spec, reason})
      end
    else
      # Unknown / Proxy impl in inbound: skip but record for visibility.
      # The expansion may later promote more peers to Stateful; until
      # then, swallow silently to keep the control plane decoupled
      # from impl details.
      {refs_acc, mon_acc}
    end
  end

  defp resolve_impl(impl_str) when is_binary(impl_str) do
    String.to_existing_atom("Elixir." <> impl_str)
  rescue
    ArgumentError -> nil
  end

  # PR-3 heuristic: every peer already spawned is passed as a named
  # neighbor (keyword list). Each peer's `init/1` picks the names it
  # wants (`:cc_process`, `:feishu_app_proxy`, ...). Matches the
  # `Keyword.get/2` pattern used by the existing Stateful peers.
  defp build_neighbors(refs_acc) do
    Enum.map(refs_acc, fn {name, pid_or_marker} ->
      {name, pid_or_marker}
    end)
  end

  defp build_ctx(%{"impl" => "Esr.Peers.FeishuAppProxy", "target" => tgt}, params) do
    app_id = get_param(params, :app_id) || "default"
    expanded = String.replace(tgt, "${app_id}", app_id)

    sym =
      case String.split(expanded, "::", parts: 2) do
        [_, admin_peer_name] -> String.to_atom(admin_peer_name)
        [admin_peer_name] -> String.to_atom(admin_peer_name)
      end

    target_pid =
      case safe_admin_peer(sym) do
        {:ok, pid} -> pid
        _ -> nil
      end

    %{
      principal_id: get_param(params, :principal_id),
      target_pid: target_pid,
      app_id: app_id
    }
  end

  defp build_ctx(%{"impl" => "Esr.Peers.CCProxy"}, params) do
    %{principal_id: get_param(params, :principal_id)}
  end

  defp build_ctx(_, _params), do: %{}

  defp spawn_args(%{"impl" => "Esr.Peers.FeishuChatProxy"}, params) do
    %{
      chat_id: get_param(params, :chat_id) || "",
      thread_id: get_param(params, :thread_id) || ""
    }
  end

  defp spawn_args(%{"impl" => "Esr.Peers.CCProcess"}, params) do
    %{handler_module: get_param(params, :handler_module) || "cc_adapter_runner"}
  end

  defp spawn_args(%{"impl" => "Esr.Peers.TmuxProcess"}, params) do
    name = "esr_cc_#{:erlang.unique_integer([:positive])}"
    %{session_name: name, dir: get_param(params, :dir) || "/tmp"}
  end

  defp spawn_args(%{"impl" => "Esr.Peers.FeishuAppAdapter"}, params) do
    %{app_id: get_param(params, :app_id) || "default"}
  end

  defp spawn_args(_, _), do: %{}

  defp register(session_id, params, refs_map) do
    Esr.SessionRegistry.register_session(
      session_id,
      %{
        chat_id: get_param(params, :chat_id) || "",
        thread_id: get_param(params, :thread_id) || ""
      },
      refs_map
    )
  end

  # Params may arrive either atom-keyed (Elixir callers) or
  # string-keyed (yaml/JSON). Accept both without forcing callers to
  # normalise.
  defp get_param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  # Safe wrapper around AdminSessionProcess.admin_peer/1 — returns
  # `:error` rather than crashing when AdminSessionProcess isn't
  # running (isolated unit-test setups).
  defp safe_admin_peer(sym) do
    case Process.whereis(Esr.AdminSessionProcess) do
      nil -> :error
      _pid -> Esr.AdminSessionProcess.admin_peer(sym)
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end
end

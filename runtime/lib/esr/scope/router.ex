defmodule Esr.Scope.Router do
  @moduledoc """
  Control-plane coordinator for Session lifecycle.

  Accepts only control-plane events:
    * `:create_session_sync`   — from `Esr.Commands.Scope.New`
    * `:end_session_sync`      — from `Esr.Commands.Scope.End`
    * `:new_chat_thread`       — PubSub broadcast from `FeishuAppAdapter`
                                 on `lookup_by_chat_thread → :not_found`.
                                 Topic `"session_router"`, tuple shape
                                 `{:new_chat_thread, app_id, chat_id,
                                 thread_id, envelope}`. P3-7 promotes
                                 this from log-only to auto-create via
                                 `Esr.Session.AgentSpawner.do_create/1`.
    * `:peer_crashed`          — internal, raised by `Process.monitor`
                                 DOWNs on spawned peer pids
    * `:agents_yaml_reloaded`  — from `Esr.Entity.Agent.Registry` watcher (stub;
                                 handled by a no-op `handle_info` clause
                                 in PR-3)

  Spec §3.3 (control-plane trinity), §6 Risk E (data-plane boundary).

  ## R6 split (2026-05-04)

  Pre-R6 this module mixed five concerns: lifecycle coordination,
  spawn pipeline mechanics, neighbor wiring, per-Entity ctx
  construction, and workspace `start_cmd` resolution. R6 extracted
  the middle three to `Esr.Session.AgentSpawner`
  (`@behaviour Esr.Interface.Spawner`); M-4 inlined `start_cmd`
  resolution as `Esr.Session.AgentSpawner.resolve_start_cmd/2`.
  This module now coordinates lifecycle events only.

  ## Risk E — data-plane boundary

  The data-plane hot path (inbound/outbound user-message traffic) must
  **not** pass through this GenServer. `handle_call/3` rejects any
  unexpected shape with `{:error, :not_control_plane}` and a WARN log;
  `handle_info/2` drops unexpected shapes with a WARN and stays alive.
  Tests in `session_router_test.exs` assert this contract.
  """

  @behaviour Esr.Role.Pipeline
  use GenServer
  require Logger

  alias Esr.Session.AgentSpawner

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

  @doc """
  Back-compat shim. Delegates to
  `Esr.Session.AgentSpawner.parse_channel_adapter/1`. New callers
  should call AgentSpawner directly.
  """
  @spec parse_channel_adapter(String.t()) :: {:ok, String.t()}
  defdelegate parse_channel_adapter(target), to: AgentSpawner

  @doc false
  defdelegate build_ctx_for_test(spec, params), to: AgentSpawner

  @doc false
  defdelegate stamp_channel_adapter_for_test(agent_def, params), to: AgentSpawner

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl true
  def init(_) do
    sub_result = subscribe_to_new_chat_thread()
    Logger.info("Scope.Router.init: subscribe_to_new_chat_thread returned #{inspect(sub_result)}")
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:create_session_sync, params}, _from, state) do
    case AgentSpawner.do_create(params) do
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
    via = {:via, Registry, {Esr.Scope.Registry, {:session_sup, sid}}}

    case GenServer.whereis(via) do
      nil ->
        {:reply, {:error, :unknown_session}, state}

      pid when is_pid(pid) ->
        :ok = Esr.Scope.Supervisor.stop_session(pid)
        :ok = Esr.Resource.ChatScope.Registry.unregister_session(sid)
        {:reply, :ok, state}
    end
  end

  # Risk E: reject anything shaped like data-plane via call.
  def handle_call(unexpected, _from, state) do
    Logger.warning(
      "Scope.Router: rejected unexpected call #{inspect(unexpected)} (Risk E boundary)"
    )

    {:reply, {:error, :not_control_plane}, state}
  end

  @impl true
  def handle_info({:new_chat_thread, app_id, chat_id, thread_id, envelope}, state) do
    Logger.info(
      "Scope.Router.handle_info(:new_chat_thread): RECEIVED " <>
        "app_id=#{inspect(app_id)} chat_id=#{inspect(chat_id)}"
    )

    # P3-7: auto-spawn a session for a previously-unseen (chat_id,
    # thread_id). Tuple order is `{app_id, chat_id, thread_id, envelope}`
    # — app_id first, matching the wiring owned by FeishuAppAdapter.
    #
    # Defaults: agent "cc" (the single agent in PR-3 scope), principal
    # pulled from the envelope when present. On create failure we log +
    # emit telemetry but keep the router alive (Risk E).
    principal_id = extract_principal(envelope)

    params = %{
      agent: "cc",
      dir: default_session_dir(),
      principal_id: principal_id,
      chat_id: chat_id,
      thread_id: thread_id,
      app_id: app_id
    }

    case AgentSpawner.do_create(params) do
      {:ok, sid, monitor_refs} ->
        :telemetry.execute(
          [:esr, :session_router, :new_chat_thread_auto_created],
          %{count: 1},
          %{session_id: sid, chat_id: chat_id, thread_id: thread_id, app_id: app_id}
        )

        Logger.info(
          "session_router: auto-created session #{sid} for new_chat_thread " <>
            "app_id=#{inspect(app_id)} chat_id=#{inspect(chat_id)} " <>
            "thread_id=#{inspect(thread_id)}"
        )

        # PR-9 T7: re-deliver the triggering envelope to the newly
        # spawned FeishuChatProxy. Without this, the first inbound
        # message that triggered the auto-create is silently lost —
        # CC never sees it, user expects a reply they never get.
        _ = redeliver_triggering_envelope(chat_id, app_id, thread_id, envelope)

        monitors =
          Enum.reduce(monitor_refs, state.monitors, fn {ref, pid}, acc ->
            Map.put(acc, ref, {sid, pid})
          end)

        {:noreply, %{state | monitors: monitors}}

      {:error, reason} ->
        :telemetry.execute(
          [:esr, :session_router, :new_chat_thread_failed],
          %{count: 1},
          %{
            chat_id: chat_id,
            thread_id: thread_id,
            app_id: app_id,
            reason: inspect(reason)
          }
        )

        Logger.warning(
          "session_router: new_chat_thread auto-create failed app_id=#{inspect(app_id)} " <>
            "chat_id=#{inspect(chat_id)} thread_id=#{inspect(thread_id)} " <>
            "reason=#{inspect(reason)}"
        )

        {:noreply, state}
    end
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
      "Scope.Router: dropped unexpected info #{inspect(msg)} (Risk E boundary)"
    )

    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp subscribe_to_new_chat_thread do
    # P3-7: subscribe to the `session_router` topic for
    # `{:new_chat_thread, app_id, chat_id, thread_id, envelope}` events
    # broadcast by FeishuAppAdapter on `lookup_by_chat_thread → :not_found`.
    #
    # Only subscribe if the PubSub is running. In isolated unit tests
    # that don't boot `EsrWeb.PubSub`, skipping the subscribe keeps
    # `init/1` from crashing the test supervisor.
    case Process.whereis(EsrWeb.PubSub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.subscribe(EsrWeb.PubSub, "session_router")
    end
  end

  # PR-9 T7: after Scope.Router auto-creates a session in response to
  # :new_chat_thread, re-deliver the triggering envelope to the fresh
  # session's FeishuChatProxy. The SessionRegistry entry is already
  # populated because `AgentSpawner.do_create/1` calls
  # `register_session/3` on its success path; we just need to look it
  # up and send the message.
  defp redeliver_triggering_envelope(chat_id, app_id, _thread_id, envelope) do
    case Esr.Resource.ChatScope.Registry.lookup_by_chat(chat_id, app_id) do
      {:ok, _sid, %{feishu_chat_proxy: proxy_pid}} when is_pid(proxy_pid) ->
        send(proxy_pid, {:feishu_inbound, envelope})
        :ok

      _ ->
        # Degraded: the pipeline didn't spawn a FeishuChatProxy. Log and
        # continue; the inbound is lost but the session is live so
        # subsequent messages will route via FAA's normal lookup path.
        Logger.warning(
          "session_router: auto-create succeeded but no feishu_chat_proxy " <>
            "in refs for chat_id=#{inspect(chat_id)} app_id=#{inspect(app_id)} " <>
            "— triggering envelope dropped"
        )

        :ok
    end
  end

  # P3-7: pull principal from the envelope if present. Feishu envelopes
  # carry the submitter's open_id under `payload.sender.open_id` when the
  # adapter_runner normalises the event; fall back to nil so `verify_caps`
  # handles the missing case uniformly.
  defp extract_principal(envelope) when is_map(envelope) do
    get_in(envelope, ["payload", "sender", "open_id"]) ||
      get_in(envelope, ["payload", "sender", "sender_id", "open_id"]) ||
      get_in(envelope, ["principal_id"]) ||
      nil
  end

  defp extract_principal(_), do: nil

  # P3-7: agent-sessions opened by auto-spawn land in a neutral working
  # directory; the slash-path (`Session.New`) explicit `dir` param
  # overrides this when a user starts a session manually.
  defp default_session_dir, do: System.tmp_dir!() || "/tmp"
end

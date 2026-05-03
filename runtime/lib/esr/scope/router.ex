defmodule Esr.Scope.Router do
  @moduledoc """
  Control-plane coordinator for Session lifecycle.

  Accepts only control-plane events:
    * `:create_session_sync`   — from `Esr.Admin.Commands.Scope.New`
    * `:end_session_sync`      — from `Esr.Admin.Commands.Scope.End`
    * `:new_chat_thread`       — PubSub broadcast from `FeishuAppAdapter`
                                 on `lookup_by_chat_thread → :not_found`.
                                 Topic `"session_router"`, tuple shape
                                 `{:new_chat_thread, app_id, chat_id,
                                 thread_id, envelope}`. P3-7 promotes
                                 this from log-only to auto-create via
                                 `do_create/1`.
    * `:peer_crashed`          — internal, raised by `Process.monitor`
                                 DOWNs on spawned peer pids
    * `:agents_yaml_reloaded`  — from `Esr.Entity.Agent.Registry` watcher (stub;
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
    calls `Entity.Factory.spawn_peer/5` for every element. In the current
    codebase, `Peer.Proxy` modules (e.g. `Esr.Entity.CCProxy`,
    `Esr.Entity.FeishuAppProxy`) are **stateless forwarder modules** —
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
    `start_supervised!(Esr.Scope.Router)` it directly. `Session.New`
    still goes through `Scope.Supervisor.start_session/1` (legacy
    path) until a follow-up subtask rewires it.
  """

  @behaviour Esr.Role.Pipeline
  use GenServer
  require Logger

  @stateful_impls MapSet.new([
                    Esr.Entity.FeishuChatProxy,
                    Esr.Entity.CCProcess,
                    Esr.Entity.PtyProcess,
                    Esr.Entity.FeishuAppAdapter,
                    # P4a-9 additions. VoiceASR/VoiceTTS are pooled in
                    # Scope.Admin and NOT spawned per-session (the
                    # `cc-voice` pipeline references them only via the
                    # VoiceASRProxy/VoiceTTSProxy). VoiceE2E is
                    # per-session and needs to be spawned.
                    Esr.Entity.VoiceE2E
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

  @channel_adapter_regex ~r/^admin::([a-z0-9_]+)_adapter_.*$/

  @doc """
  Extract the channel adapter family from a proxy target string.

  Regex captures the entire token before `_adapter_`, so
  `"admin::feishu_app_adapter_default"` returns `"feishu_app"` (the family
  includes underscored suffixes). Non-matching strings fall back to
  `"feishu"` and emit a `Logger.warning`.
  """
  @spec parse_channel_adapter(String.t()) :: {:ok, String.t()}
  def parse_channel_adapter(target) when is_binary(target) do
    case Regex.run(@channel_adapter_regex, target) do
      [_, family] ->
        {:ok, family}

      _ ->
        Logger.warning(
          "channel_adapter: non-matching proxy target target=#{inspect(target)} " <>
            "falling back to feishu"
        )

        {:ok, "feishu"}
    end
  end

  @doc false
  # Test-only shim: lets D1's ExUnit reach the private build_ctx/2
  # clauses without smuggling in a whole Session. Keep the shim narrow —
  # delegates directly to the same private function.
  def build_ctx_for_test(spec, params), do: build_ctx(spec, params)

  @doc false
  def stamp_channel_adapter_for_test(agent_def, params) do
    proxies = agent_def.proxies || []

    channel_adapter =
      proxies
      |> Enum.find_value(fn
        %{"target" => tgt} when is_binary(tgt) ->
          {:ok, fam} = parse_channel_adapter(tgt)
          fam

        _ ->
          nil
      end)
      |> Kernel.||("feishu")

    Map.put(params, :channel_adapter, channel_adapter)
  end

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

    case do_create(params) do
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
  # populated because `do_create/1` calls `register_session/3` on its
  # success path; we just need to look it up and send the message.
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

  defp do_create(params) do
    with {:ok, agent_name} <- fetch_agent_name(params),
         {:ok, agent_def} <- fetch_agent(agent_name),
         session_id <- gen_id(),
         params <- enrich_params(params, session_id),
         {:ok, _sup} <- start_session_sup(session_id, agent_name, params, agent_def),
         {:ok, refs_map, mon} <- spawn_pipeline(session_id, agent_def, params),
         :ok <- register(session_id, params, refs_map) do
      {:ok, session_id, mon}
    end
  end

  # PR-9 T11b.2: thread `session_id` and `workspace_name` into the params
  # map so downstream peers' `spawn_args/1` callbacks can read them
  # without having to re-derive. `workspace_name` is resolved via
  # `Esr.Resource.Workspace.Registry.workspace_for_chat/2` when the caller
  # didn't supply one explicitly. Falls back to `"default"` — not nil —
  # so peers downstream always see a string.
  defp enrich_params(params, session_id) do
    chat_id = get_param(params, :chat_id) || ""
    app_id = get_param(params, :app_id) || "default"

    workspace_name =
      get_param(params, :workspace_name) ||
        case Esr.Resource.Workspace.Registry.workspace_for_chat(chat_id, app_id) do
          {:ok, name} -> name
          :not_found -> "default"
        end

    # PR-21ξ 2026-05-01: read the workspace's `start_cmd` (when set in
    # workspaces.yaml) and inject as a peer param so the launching peer
    # uses the operator-configured launcher instead of the hardcoded
    # `claude …` argv. Without this, `start_cmd: scripts/esr-cc.sh`
    # was dead config — peers always fell through to the default
    # `["claude", …]`. esr-cc.sh sources ~/.zshrc + adds ~/.local/bin
    # to PATH, so routing through it is the right fix.
    start_cmd = resolve_workspace_start_cmd(workspace_name, params)

    params
    |> Map.put(:session_id, session_id)
    |> Map.put(:workspace_name, workspace_name)
    |> maybe_put_start_cmd(start_cmd)
  end

  defp resolve_workspace_start_cmd(workspace_name, params)
       when is_binary(workspace_name) do
    # Caller-supplied :start_cmd wins (test injection, future per-session
    # override). Otherwise look up workspaces.yaml.
    raw =
      case get_param(params, :start_cmd) do
        cmd when is_binary(cmd) and cmd != "" ->
          cmd

        _ ->
          case Esr.Resource.Workspace.Registry.get(workspace_name) do
            {:ok, %{start_cmd: cmd}} when is_binary(cmd) and cmd != "" ->
              cmd

            _ ->
              nil
          end
      end

    expand_start_cmd(raw)
  end

  defp resolve_workspace_start_cmd(_, _), do: nil

  # PR-21ρ 2026-05-01: workspaces.yaml's `start_cmd` is conventionally a
  # repo-relative path (`scripts/esr-cc.sh`). The peer's cwd is the
  # session's worktree (or `/tmp` for auto-created sessions), so a
  # relative path won't resolve. Prepend `$ESR_REPO_DIR` (set by the
  # launchd plist) when the start_cmd doesn't already look absolute.
  defp expand_start_cmd(nil), do: nil
  defp expand_start_cmd(""), do: nil

  defp expand_start_cmd(cmd) when is_binary(cmd) do
    [head | rest] = String.split(cmd, " ", parts: 2, trim: true)

    head =
      cond do
        String.starts_with?(head, "/") ->
          head

        String.starts_with?(head, "~") ->
          String.replace_prefix(head, "~", System.get_env("HOME") || "")

        true ->
          case System.get_env("ESR_REPO_DIR") do
            repo when is_binary(repo) and repo != "" -> Path.join(repo, head)
            _ -> head
          end
      end

    Enum.join([head | rest], " ")
  end

  defp maybe_put_start_cmd(params, nil), do: params
  defp maybe_put_start_cmd(params, cmd), do: Map.put(params, :start_cmd, cmd)

  defp fetch_agent_name(params) do
    case params[:agent] || params["agent"] do
      nil -> {:error, :agent_required}
      name when is_binary(name) -> {:ok, name}
    end
  end

  defp fetch_agent(name) do
    case Esr.Entity.Agent.Registry.agent_def(name) do
      {:ok, d} -> {:ok, d}
      {:error, :not_found} -> {:error, :unknown_agent}
    end
  end

  # ULID-ish — 96 bits encoded base32 (no padding). Good enough for
  # session identity; callers get an opaque binary id.
  defp gen_id, do: :crypto.strong_rand_bytes(12) |> Base.encode32(padding: false)

  defp start_session_sup(sid, agent_name, params, agent_def) do
    chat_id = get_param(params, :chat_id) || ""
    app_id = get_param(params, :app_id) || "default"
    principal_id = get_param(params, :principal_id)
    dir = get_param(params, :dir)

    # PR-21λ: chat_thread_key narrowed to the 2-tuple routing key.
    # `thread_id` for Feishu reply rendering still flows through the
    # FCP via per-peer params, not via this struct.
    Esr.Scope.Supervisor.start_session(%{
      session_id: sid,
      agent_name: agent_name,
      dir: dir,
      chat_thread_key: %{chat_id: chat_id, app_id: app_id},
      metadata: %{principal_id: principal_id, agent_def: agent_def}
    })
  end

  # Spawn every Stateful peer in inbound order; record Proxy modules
  # symbolically without spawning. Monitor each spawned pid so DOWNs
  # feed back into handle_info/2's peer_crashed telemetry.
  #
  # PR-9 T6 — bidirectional neighbors (two-pass). Pre-T6 each peer was
  # spawned with a forward-only neighbors keyword list (only peers
  # already spawned were visible). That left FeishuChatProxy without
  # its `:cc_process` or `:feishu_app_proxy` neighbors and CCProcess
  # without its `:pty_process` or `:feishu_chat_proxy` neighbors — so
  # T5's react-emit path dropped with `:no_app_proxy_neighbor` and the
  # CC reply path had nowhere to go.
  #
  # The fix is a post-spawn back-wire pass: once every Stateful peer is
  # spawned and every proxy target resolved, compute the full adjacency
  # (inbound pids + proxy-target pids) and patch each spawned peer's
  # `state.neighbors` via `:sys.replace_state/2`. `create_session/1` is
  # synchronous and the session isn't published to `SessionRegistry`
  # until AFTER we return, so there's no data-plane race here.
  #
  # Proxy-neighbor resolution: proxies with a `target: "admin::..."` are
  # resolved to the real admin-peer pid (e.g. FeishuAppAdapter) so FCP's
  # `emit_to_feishu_app_proxy` (T5) can `send(pid, {:outbound, ...})`
  # directly. Refs keep the stateless `{:proxy_module, Mod}` marker for
  # discoverability; peer-state neighbors get the usable pid.
  defp spawn_pipeline(session_id, agent_def, params) do
    inbound = agent_def.pipeline.inbound || []
    proxies = agent_def.proxies || []
    # D1: lift `channel_adapter` from the first matching proxy target so
    # downstream peers (FeishuChatProxy, CCProcess) see it via their ctx.
    params = stamp_channel_adapter_for_test(agent_def, params)

    try do
      {refs, monitors} =
        Enum.reduce(inbound, {%{}, []}, fn spec, {refs_acc, mon_acc} ->
          spawn_one(session_id, spec, params, refs_acc, mon_acc)
        end)

      # Proxies are stateless modules — no pid, no monitor. Record
      # them so `lookup_by_chat_thread/3` can surface the wiring for
      # callers that need to know "which Proxy module forwards where."
      refs =
        Enum.reduce(proxies, refs, fn spec, acc ->
          name = String.to_atom(spec["name"])
          impl = resolve_impl(spec["impl"])
          Map.put(acc, name, {:proxy_module, impl})
        end)

      # T6: back-wire every spawned peer with the full bidirectional
      # neighbors keyword (inbound pids + resolved proxy-target pids).
      :ok = backwire_neighbors(refs, proxies, params)

      {:ok, refs, monitors}
    catch
      {:spawn_failed, spec, reason} ->
        {:error, {:peer_spawn_failed, spec, reason}}
    end
  end

  # PR-9 T6: patch `state.neighbors` on every spawned pid after all
  # peers have been spawned. For OSProcess-backed peers the inner peer
  # state lives under `worker_state.state`; we detect that wrapper and
  # recurse into it. All other peers carry `state.neighbors` directly
  # at the top level.
  defp backwire_neighbors(refs, proxy_specs, params) do
    # Inbound stateful peers contribute their pid directly.
    inbound_entries =
      refs
      |> Enum.filter(fn {_name, v} -> is_pid(v) end)
      |> Enum.map(fn {name, pid} -> {name, pid} end)

    # Proxies contribute a resolved admin-peer pid when target is
    # `admin::...`. Proxies whose target doesn't resolve (missing
    # admin peer, no target, pool-binding proxies like VoiceASRProxy)
    # are still added to neighbors under the `{:proxy_module, Mod}`
    # marker so peers can decide their own fallback behaviour.
    proxy_entries =
      Enum.map(proxy_specs, fn spec ->
        name = String.to_atom(spec["name"])
        impl = resolve_impl(spec["impl"])
        target = spec["target"]

        value =
          case resolve_proxy_target(target, params) do
            {:ok, pid} when is_pid(pid) -> pid
            _ -> {:proxy_module, impl}
          end

        {name, value}
      end)

    full = inbound_entries ++ proxy_entries

    Enum.each(inbound_entries, fn {name, pid} ->
      others = Enum.reject(full, fn {n, _} -> n == name end)

      _ =
        :sys.replace_state(pid, fn
          # OSProcessWorker wrapper: %{parent: _, state: inner, ...}
          %{parent: _, state: inner} = ws when is_map(inner) ->
            %{ws | state: %{inner | neighbors: others}}

          # Plain peer state map
          %{neighbors: _} = s ->
            %{s | neighbors: others}

          # Defensive fallthrough — peer without a neighbors key
          # (shouldn't happen for our Stateful impls, but don't
          # crash the router on an unexpected shape).
          other ->
            other
        end)

      :ok
    end)

    :ok
  end

  # Resolve a proxies-block `target` string (e.g.
  # `"admin::feishu_app_adapter_${app_id}"`) to the live admin-peer pid.
  # Returns `{:ok, pid}` on success, `:error` otherwise. Missing targets
  # and non-`admin::` targets (e.g. `admin::voice_asr_pool` — which IS
  # admin::, but the pool case is intentionally left unresolved here —
  # VoiceASRProxy runs its own pool-acquire, not a raw send to a pid)
  # fall through.
  defp resolve_proxy_target(nil, _params), do: :error

  defp resolve_proxy_target(target, params) when is_binary(target) do
    app_id = get_param(params, :app_id) || "default"
    expanded = String.replace(target, "${app_id}", app_id)

    case String.split(expanded, "::", parts: 2) do
      ["admin", admin_peer_name] ->
        sym = String.to_atom(admin_peer_name)

        case safe_admin_peer(sym) do
          {:ok, pid} when is_pid(pid) -> {:ok, pid}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp spawn_one(session_id, spec, params, refs_acc, mon_acc) do
    name = String.to_atom(spec["name"])
    impl = resolve_impl(spec["impl"] || "")

    if MapSet.member?(@stateful_impls, impl) do
      neighbors = build_neighbors(refs_acc)
      ctx = build_ctx(spec, params)
      args = spawn_args(impl, spec, params)

      case Esr.Entity.Factory.spawn_peer(session_id, impl, args, neighbors, ctx) do
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

  defp build_ctx(%{"impl" => "Esr.Entity.FeishuAppProxy", "target" => tgt}, params) do
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

    {:ok, channel_adapter} = parse_channel_adapter(expanded)

    %{
      principal_id: get_param(params, :principal_id),
      target_pid: target_pid,
      app_id: app_id,
      channel_adapter: channel_adapter
    }
  end

  defp build_ctx(%{"impl" => "Esr.Entity.CCProxy"}, params) do
    %{principal_id: get_param(params, :principal_id)}
  end

  # PR-E (2026-04-27 actor-topology-routing): CCProcess needs
  # `workspace_name`, `chat_id`, `app_id`, and `channel_adapter` in
  # `proxy_ctx` so its `init/1` can call `Esr.Topology.initial_seed/3`
  # to seed the BGP `reachable_set` from the yaml-declared neighbours.
  # Pre-PR-E the CCProcess fell through to the catch-all `build_ctx/2`
  # which returned `%{channel_adapter: family}` — the missing
  # workspace_name made `build_initial_reachable_set/1` fall back to
  # an empty MapSet, so the `<channel reachable=...>` attribute never
  # carried neighbour URIs.
  defp build_ctx(%{"impl" => "Esr.Entity.CCProcess"}, params) do
    %{
      workspace_name: get_param(params, :workspace_name),
      chat_id: get_param(params, :chat_id),
      app_id: get_param(params, :app_id),
      channel_adapter: get_param(params, :channel_adapter)
    }
  end

  # P4a-9: VoiceASRProxy / VoiceTTSProxy ctx — attach the symbolic
  # pool_name the proxy uses to acquire/release workers from
  # Scope.Admin's pool. acquire_timeout is a conservative default
  # (5s); can be overridden per-agent in a future PR.
  defp build_ctx(%{"impl" => "Esr.Entity.VoiceASRProxy"}, params) do
    %{
      principal_id: get_param(params, :principal_id),
      pool_name: :voice_asr_pool,
      acquire_timeout: 5_000
    }
  end

  defp build_ctx(%{"impl" => "Esr.Entity.VoiceTTSProxy"}, params) do
    %{
      principal_id: get_param(params, :principal_id),
      pool_name: :voice_tts_pool,
      acquire_timeout: 5_000
    }
  end

  defp build_ctx(_, params) do
    case get_param(params, :channel_adapter) do
      nil -> %{}
      family -> %{channel_adapter: family}
    end
  end

  # Generic per-peer dispatch: each Stateful peer may export
  # `spawn_args/1` (params -> init_args map). Peers that don't define
  # it fall through to `Esr.Entity.default_spawn_args/1` (empty map).
  defp spawn_args(impl_module, _spec, params) do
    if Code.ensure_loaded?(impl_module) and
         function_exported?(impl_module, :spawn_args, 1) do
      impl_module.spawn_args(params)
    else
      Esr.Entity.default_spawn_args(params)
    end
  end

  defp register(session_id, params, refs_map) do
    # PR-21λ: routing key dropped thread_id. The full chat-binding map
    # still lives in `params` for FCP/CC reply rendering — this only
    # narrows what `ChatScope.Registry` indexes on.
    Esr.Resource.ChatScope.Registry.register_session(
      session_id,
      %{
        chat_id: get_param(params, :chat_id) || "",
        app_id: get_param(params, :app_id) || "default"
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

  # Safe wrapper around Scope.Admin.Process.admin_peer/1 — returns
  # `:error` rather than crashing when Scope.Admin.Process isn't
  # running (isolated unit-test setups).
  defp safe_admin_peer(sym) do
    case Process.whereis(Esr.Scope.Admin.Process) do
      nil -> :error
      _pid -> Esr.Scope.Admin.Process.admin_peer(sym)
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end
end

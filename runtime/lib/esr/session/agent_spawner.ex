defmodule Esr.Session.AgentSpawner do
  @moduledoc """
  Stateless agent-Session spawner. Receives an agent declaration
  (`agent_def`) from the caller and instantiates a runtime Scope
  subtree by spawning every `pipeline.inbound` Stateful Entity,
  recording stateless Proxy modules symbolically, and back-wiring
  bidirectional neighbors.

  ## Phase 5/6 cut-over (2026-05-10)

  Pre-Phase-5 this module fetched the agent_def from
  `Esr.Entity.Agent.Registry.agent_def/1` (the agents.yaml cache).
  Phase 5 (spec §5.4) hardcut that source: callers now thread the
  agent_def through `params[:agent_def]`, materialized from a
  SessionTemplate via `Esr.SessionTemplate.Registry.materialize/2`.
  Phase 6 (same spec, §6) dissolved the agents.yaml file outright —
  the per-kind contributions (pipeline peers, capabilities) now flow
  from each plugin's manifest `agent_kinds:` block (registered into
  `Esr.Plugin.AgentKindRegistry`) through AgentDefBuilder. The
  agent_def map shape is unchanged (the walker still consumes
  `pipeline.inbound`, `proxies`, etc verbatim) — only the SOURCE
  swapped.

  Implements `Esr.Interface.Spawner`. Extracted from
  `Esr.Session.Router` in R6 of the structural refactor
  (`docs/notes/structural-refactor-plan-r4-r11.md` §四-R6).

  ## Why a separate module

  `Esr.Session.Router` was a 799-LOC GenServer mixing five concerns:
  lifecycle coordination, spawn pipeline mechanics, neighbor wiring,
  per-Entity ctx construction, and workspace `start_cmd` resolution.
  AgentSpawner owns the middle three plus (M-4) `start_cmd`
  resolution; lifecycle stays in `Scope.Router`.

  ## API shape

    * `spawn/3`         — `Esr.Interface.Spawner` callback. Reads the
                          agent declaration from the supplied `decl`
                          map (the materialized agent_def — pre-Phase-6
                          sourced from agents.yaml, post-Phase-6 from
                          a SessionTemplate + plugin manifest agent_kinds)
                          and spawns the Session subtree under
                          `Esr.Session.Supervisor`. Returns
                          `{:ok, session_sup_pid}` on success.
    * `terminate/2`     — `Esr.Interface.Spawner` callback. Tears down
                          a Session subtree by its scope_id.
    * `do_create/1`     — caller-friendly entry point used by
                          `Scope.Router`. Returns
                          `{:ok, session_id, monitor_refs}` so Router
                          can register the monitors against its DOWN
                          handler. This is the original `do_create/1`
                          extracted unchanged.

  ## Drift from the spawner contract

  `Esr.Interface.Spawner.spawn/3` returns `{:ok, scope_pid}` (the
  supervisor pid). The `Scope.Router` lifecycle path needs more than
  just the pid — it needs the `session_id` (for caller reply) and the
  `monitor_refs` (so the Router can map DOWN to peer crash). We expose
  both shapes:

    * `spawn/3` for Spawner-Interface conformance — returns the
      supervisor pid only.
    * `do_create/1` for Router-internal use — returns the rich tuple.

  ## Risk E

  This module is data-plane-blind. It only inspects the static agent
  declaration + per-spawn params; never sees user-message envelopes.
  """

  @behaviour Esr.Interface.Spawner
  require Logger

  # PR-3.2: replaced compile-time MapSet with runtime registry.
  # Core registers `Esr.Entity.PtyProcess` at boot; plugins register
  # their own stateful peers via manifest `entities: [...]` blocks
  # with `kind: stateful` (feishu plugin → FeishuChatProxy +
  # FeishuAppAdapter; claude_code plugin → CCProcess). Reads go
  # through `Esr.Entity.Agent.StatefulRegistry.stateful?/1`.

  @channel_adapter_regex ~r/^admin::([a-z0-9_]+)_adapter_.*$/

  # ------------------------------------------------------------------
  # Public — Spawner Interface
  # ------------------------------------------------------------------

  @impl Esr.Interface.Spawner
  @doc """
  `Esr.Interface.Spawner` entry. `decl` is the materialized agent_def
  map (pre-Phase-6 sourced from `Esr.Entity.Agent.Registry.agent_def/1`,
  post-Phase-6 from `Esr.SessionTemplate.Registry.materialize/2`);
  `params` carries per-instance data; `ctx` is currently unused
  (kept for Interface conformance).

  Returns the spawned Session supervisor pid on success.
  """
  @spec spawn(map(), map(), map()) :: {:ok, pid()} | {:error, term()}
  def spawn(decl, params, _ctx) when is_map(decl) and is_map(params) do
    # decl is the agent_def. We synthesize an agent_name when the
    # caller supplied one in params, otherwise fall back to the
    # decl's own name.
    agent_name = get_param(params, :agent) || Map.get(decl, :name) || Map.get(decl, "name")

    # Phase 5 cut-over: thread the agent_def from `decl` into
    # `params[:agent_def]` so `do_create/1` finds it. Pre-Phase-5
    # `do_create` looked it up via the legacy agents.yaml cache;
    # post-cut callers must always supply it.
    enriched_params =
      params
      |> Map.put(:agent, agent_name)
      |> Map.put_new(:agent_def, decl)

    case do_create(enriched_params) do
      {:ok, session_id, _monitor_refs} ->
        via = {:via, Registry, {Esr.Session.Registry, {:session_sup, session_id}}}

        case GenServer.whereis(via) do
          pid when is_pid(pid) -> {:ok, pid}
          nil -> {:error, :session_not_registered}
        end

      {:error, _reason} = err ->
        err
    end
  end

  @impl Esr.Interface.Spawner
  @doc """
  `Esr.Interface.Spawner` teardown. Symmetric to
  `Esr.Session.Router.end_session/1` but routes through the supervisor
  directly instead of the lifecycle GenServer.
  """
  @spec terminate(binary(), term()) :: :ok
  def terminate(scope_id, _reason) when is_binary(scope_id) do
    via = {:via, Registry, {Esr.Session.Registry, {:session_sup, scope_id}}}

    case GenServer.whereis(via) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        :ok = Esr.Session.Supervisor.stop_session(pid)
        :ok = Esr.Session.ChatRouting.Registry.unregister_session(scope_id)
        :ok
    end
  end

  # ------------------------------------------------------------------
  # Public — Router-internal entry (extracted do_create/1)
  # ------------------------------------------------------------------

  @doc """
  Coordinator-friendly entry: returns the rich tuple
  `{:ok, session_id, monitor_refs}` that `Esr.Session.Router` needs to
  register its peer-DOWN monitors. Callers outside Router should
  prefer `spawn/3`.

  ## Phase 5/6 hardcut on the agent_def source

  Pre-Phase-5 this function fetched `agent_def` from
  `Esr.Entity.Agent.Registry.agent_def/1` (the agents.yaml cache).
  Phase 5 inverts the responsibility: callers MUST pass an
  `:agent_def` map in `params`. The map shape is unchanged (same
  fields the walker reads) but its source is now
  `Esr.SessionTemplate.Registry.materialize/2` (template-driven). In
  Phase 6 the template materializer's per-kind contributions in turn
  flow from each plugin's manifest `agent_kinds:` block. Spec §5.4 +
  §6 (`docs/superpowers/specs/2026-05-10-session-template-and-channel.md`).

  Missing `:agent_def` is a bug in the caller, not a recoverable
  runtime condition — return `{:error, :agent_def_required}` so the
  caller surfaces the integration gap.
  """
  @spec do_create(map()) ::
          {:ok, binary(), [{reference(), pid()}]} | {:error, term()}
  def do_create(params) do
    with {:ok, agent_name} <- fetch_agent_name(params),
         {:ok, agent_def} <- fetch_agent_def(params),
         session_id <- Esr.Resource.Session.Id.new(),
         params <- enrich_params(params, session_id),
         {:ok, _sup} <- start_session_sup(session_id, agent_name, params, agent_def),
         {:ok, refs_map, mon} <- spawn_pipeline(session_id, agent_def, params),
         :ok <- verify_pipeline_complete(session_id, agent_def),
         :ok <- register(session_id, params, refs_map) do
      {:ok, session_id, mon}
    end
  end

  # ------------------------------------------------------------------
  # Public — channel_adapter parser + test shims
  # ------------------------------------------------------------------

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
  def stamp_channel_adapter_for_test(agent_def, params),
    do: stamp_channel_adapter(agent_def, params)

  @doc false
  # Test-only shim: lets PR-2 T5's ExUnit reach the private
  # `verify_pipeline_complete/2` clauses without building a full session
  # subtree. The function itself only consumes the agent_def's
  # `pipeline.inbound` shape + ActorQuery, so we can drive it
  # directly with a synthetic session_id.
  def verify_pipeline_complete_for_test(sid, agent_def),
    do: verify_pipeline_complete(sid, agent_def)

  # ------------------------------------------------------------------
  # Private — pipeline spawning (extracted unchanged from Scope.Router)
  # ------------------------------------------------------------------

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

    # M-4: read start_cmd from caller params first, then fall back to the
    # workspace's `settings["start_cmd"]`. Path is expanded relative to
    # ESR_REPO_DIR if not absolute.
    start_cmd = resolve_start_cmd(workspace_name, params)

    params
    |> Map.put(:session_id, session_id)
    |> Map.put(:workspace_name, workspace_name)
    |> maybe_put_start_cmd(start_cmd)
  end

  defp maybe_put_start_cmd(params, nil), do: params
  defp maybe_put_start_cmd(params, cmd), do: Map.put(params, :start_cmd, cmd)

  defp fetch_agent_name(params) do
    case params[:agent] || params["agent"] do
      nil -> {:error, :agent_required}
      name when is_binary(name) -> {:ok, name}
    end
  end

  # Phase 5/6 cut-over: read the agent_def from params; the legacy
  # `Esr.Entity.Agent.Registry` agents.yaml cache is gone. The caller
  # (`Esr.Commands.Session.New`, `Esr.Session.Router`) is responsible
  # for materializing the agent_def from a SessionTemplate via
  # `Esr.SessionTemplate.Registry.materialize/2` (which composes
  # channel + plugin-manifest agent_kind contributions) and threading
  # it through `params[:agent_def]` (or `params["agent_def"]`).
  #
  # Spec §5.4 + §6.
  defp fetch_agent_def(params) do
    case params[:agent_def] || params["agent_def"] do
      %{} = agent_def -> {:ok, agent_def}
      _ -> {:error, :agent_def_required}
    end
  end

  defp start_session_sup(sid, agent_name, params, agent_def) do
    chat_id = get_param(params, :chat_id) || ""
    app_id = get_param(params, :app_id) || "default"
    principal_id = get_param(params, :principal_id)
    dir = get_param(params, :dir)

    # PR-21λ: chat_thread_key narrowed to the 2-tuple routing key.
    # `thread_id` for Feishu reply rendering still flows through the
    # FCP via per-peer params, not via this struct.
    Esr.Session.Supervisor.start_session(%{
      session_id: sid,
      agent_name: agent_name,
      dir: dir,
      chat_thread_key: %{chat_id: chat_id, app_id: app_id},
      metadata: %{principal_id: principal_id, agent_def: agent_def}
    })
  end

  # Spawn every Stateful peer in inbound order; record Proxy modules
  # symbolically without spawning. Monitor each spawned pid so DOWNs
  # feed back into the Router's handle_info/2 peer_crashed telemetry.
  #
  # M-2.3: PR-9 T6 backwire-via-`:sys.replace_state` deleted. Peers no
  # longer carry `state.neighbors`; routing is via
  # `Esr.ActorQuery.list_by_role/2` (Index 3) which is populated by
  # each peer's `register_attrs/2` in init. ActorQuery returns the
  # full session-level adjacency at the moment of the call — no
  # post-spawn patching, no two-pass ceremony, no race.
  defp spawn_pipeline(session_id, agent_def, params) do
    inbound = agent_def.pipeline.inbound || []
    proxies = agent_def.proxies || []
    # D1: lift `channel_adapter` from the first matching proxy target so
    # downstream peers (FeishuChatProxy, CCProcess) see it via their ctx.
    params = stamp_channel_adapter(agent_def, params)

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

      {:ok, refs, monitors}
    catch
      {:spawn_failed, spec, reason} ->
        {:error, {:peer_spawn_failed, spec, reason}}
    rescue
      # PR-2 (2026-05-11 spec rev-3): Esr.Entity.PtyProcess.spawn_args/1
      # now raises ArgumentError on nil/empty :dir (pre-PR-2 it silently
      # coerced to "/tmp"). Translate into the same structured error
      # shape that {:spawn_failed, _, _} produces so callers see a
      # uniform :peer_spawn_failed regardless of WHICH peer surfaced the
      # invariant violation.
      e in ArgumentError ->
        {:error, {:peer_spawn_failed, :spawn_args, {:bad_argument, Exception.message(e)}}}
    end
  end

  # D1 helper — extract channel_adapter family from the first matching
  # proxies-block target string and stamp into params.
  defp stamp_channel_adapter(agent_def, params) do
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

  defp spawn_one(session_id, spec, params, refs_acc, mon_acc) do
    name = String.to_atom(spec["name"])
    impl = resolve_impl(spec["impl"] || "")

    if Esr.Entity.Agent.StatefulRegistry.stateful?(impl) do
      ctx = build_ctx(spec, params)
      args = spawn_args(impl, spec, params)

      case Esr.Entity.Factory.spawn_peer(session_id, impl, args, ctx) do
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

  # CCProcess needs `workspace_name`, `chat_id`, `app_id`, and
  # `channel_adapter` in `proxy_ctx` so its `build_channel_notification`
  # can populate the `<channel>` envelope attributes downstream.
  defp build_ctx(%{"impl" => "Esr.Entity.CCProcess"}, params) do
    %{
      workspace_name: get_param(params, :workspace_name),
      chat_id: get_param(params, :chat_id),
      app_id: get_param(params, :app_id),
      channel_adapter: get_param(params, :channel_adapter)
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

  # PR-2 (2026-05-11 spec rev-3) — post-spawn pipeline integrity check.
  #
  # Pre-PR-2, if any inbound stage failed to materialize into a live actor
  # (e.g. impl module didn't load, role index write raced, custom plugin
  # contributed a stage that nobody implements) the session would register
  # as live with an incomplete pipeline — inbound messages then silently
  # dropped on missing-role lookups downstream.
  #
  # Post-spawn we verify every expected role from `agent_def.pipeline.inbound`
  # is reachable via `Esr.ActorQuery.list_by_role/2`. If any role is missing,
  # tear down via `Esr.Session.Router.end_session/1` (symmetric with the
  # session-supervisor route the spawn took) and return
  # `{:error, :pipeline_incomplete}`. Callers (Commands.Session.New)
  # surface this to chat as a structured error.
  defp verify_pipeline_complete(sid, agent_def) do
    expected_roles =
      (agent_def.pipeline.inbound || [])
      |> Enum.map(&role_for_impl(&1["impl"]))
      |> Enum.reject(&is_nil/1)

    missing =
      Enum.reject(expected_roles, fn role ->
        case Esr.ActorQuery.list_by_role(sid, role) do
          [_pid | _] -> true
          [] -> false
        end
      end)

    case missing do
      [] ->
        :ok

      missing_roles ->
        require Logger

        Logger.warning(
          "agent_spawner: pipeline_incomplete session_id=#{sid} " <>
            "missing_roles=#{inspect(missing_roles)} — tearing down"
        )

        # Best-effort teardown. Router is the canonical lifecycle owner;
        # if it's not running (narrow unit-test setups), the supervisor
        # tree was never built either, so there's nothing to tear down.
        case Process.whereis(Esr.Session.Router) do
          nil -> :ok
          _pid -> _ = Esr.Session.Router.end_session(sid)
        end

        {:error, :pipeline_incomplete}
    end
  end

  # Map the inbound stage's impl module string to the @role atom each
  # peer registers itself under (Index 3 / `Esr.ActorQuery.list_by_role/2`).
  # Stages whose impl is a Proxy (stateless module — no live actor, no
  # role to verify) return nil so they're excluded from the expected set.
  defp role_for_impl("Esr.Plugins.Feishu.FeishuChatProxy"), do: :feishu_chat_proxy
  defp role_for_impl("Esr.Entity.CCProcess"), do: :cc_process
  defp role_for_impl("Esr.Plugins.ClaudeCode.CCProcess"), do: :cc_process
  defp role_for_impl("Esr.Entity.PtyProcess"), do: :pty_process
  defp role_for_impl(_), do: nil

  defp register(session_id, params, refs_map) do
    # PR-21λ: routing key dropped thread_id. The full chat-binding map
    # still lives in `params` for FCP/CC reply rendering — this only
    # narrows what `ChatScope.Registry` indexes on.
    Esr.Session.ChatRouting.Registry.register_session(
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

  # M-4 inlined start-cmd resolution previously hosted in
  # Esr.Resource.Workspace.Registry (deleted alongside the legacy struct).
  #   1. Caller-supplied params[:start_cmd] (atom or string key) wins
  #      when non-empty.
  #   2. Otherwise read the workspace's `settings["start_cmd"]` via
  #      NameIndex → get_by_id.
  #   3. Returns nil when neither is set.
  # ESR_REPO_DIR / ~ expansion + `/`-prefix passthrough match the
  # legacy expand_start_cmd/1 contract.
  defp resolve_start_cmd(workspace_name, params) do
    raw =
      case get_param(params, :start_cmd) do
        cmd when is_binary(cmd) and cmd != "" ->
          cmd

        _ ->
          workspace_setting_start_cmd(workspace_name)
      end

    expand_start_cmd(raw)
  end

  defp workspace_setting_start_cmd(name) when is_binary(name) and name != "" do
    case Esr.Resource.Workspace.NameIndex.id_for_name(:esr_workspace_name_index, name) do
      {:ok, id} ->
        case Esr.Resource.Workspace.Registry.get_by_id(id) do
          {:ok, %{settings: settings}} when is_map(settings) ->
            Map.get(settings, "start_cmd")

          _ ->
            nil
        end

      :not_found ->
        nil
    end
  rescue
    ArgumentError -> nil
  catch
    :exit, _ -> nil
  end

  defp workspace_setting_start_cmd(_), do: nil

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

  # Safe wrapper around Scope.Admin.Process.admin_peer/1 — returns
  # `:error` rather than crashing when Scope.Admin.Process isn't
  # running (isolated unit-test setups).
  defp safe_admin_peer(sym) do
    case Process.whereis(Esr.Session.Admin.Process) do
      nil -> :error
      _pid -> Esr.Session.Admin.Process.admin_peer(sym)
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end
end

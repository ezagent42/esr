defmodule Esr.Application do
  @moduledoc """
  OTP Application entry. Starts the supervision tree declared in
  `docs/superpowers/specs/2026-04-18-esr-extraction-design.md` §3.1.

  Child order matters: PubSub and Entity.Registry must be up before any
  Entity.Server or adapter/handler subsystem can register itself.

  PRD 01 F02. Strategy `:one_for_one` — one subsystem's failure must
  not cascade to siblings (this is how Track D session-isolation is
  preserved at the top level).
  """

  use Application

  @impl Application
  def start(_type, _args) do
    # PR-21β 2026-04-30: per-boot random token injected into every
    # worker subprocess via Esr.Workers.{AdapterProcess,HandlerProcess}.
    # Python-side guards refuse to start when the env var is missing,
    # preventing operator-spawned rogue adapters from competing with
    # the esrd-managed ones (today's 8x-orphan incident motivated this).
    # Generated BEFORE Supervisor.start_link/2 so children find the
    # token via Application.get_env/2.
    spawn_token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    Application.put_env(:esr, :spawn_token, spawn_token)

    # PR-21β: one-shot residue cleanup. Pre-PR-21β builds wrote pidfiles
    # + log files under /tmp/esr-worker-*. They're now obsolete; sweep
    # them at boot once. Idempotent: subsequent boots find nothing.
    for f <- Path.wildcard("/tmp/esr-worker-*.pid") ++ Path.wildcard("/tmp/esr-worker-*.log") do
      _ = File.rm(f)
    end

    children = [
      # 1. Cluster / default Phoenix-generated children first.
      {DNSCluster, query: Application.get_env(:esr, :dns_cluster_query) || :ignore},
      EsrWeb.Telemetry,

      # 2. Message bus — everything else may publish/subscribe.
      {Phoenix.PubSub, name: EsrWeb.PubSub},

      # 3a. (M-1) IndexWatcher owns the ETS tables backing
      # Esr.Entity.Registry.register_attrs/2 (Index 2: `{session_id, name}`,
      # Index 3: `{session_id, role}`). Started BEFORE the Elixir.Registry
      # below so that any peer's init/1 — which routinely registers in
      # Index 1 and may also call register_attrs/2 — finds the tables ready.
      Esr.Entity.Registry.IndexWatcher,

      # 3. Actor registry before any Entity.Server can register itself.
      {Registry, keys: :unique, name: Esr.Entity.Registry},

      # 4. Dynamic supervisor that hosts live PeerServers.
      Esr.Entity.Supervisor,

      # 4b. Dead-letter queue — started before peers so enqueue never misses.
      {Esr.Resource.DeadLetter.Queue, name: Esr.Resource.DeadLetter.Queue},

      # 4c. Python worker launcher — on-demand adapter_runner /
      # handler_worker subprocesses for live topology instantiation
      # (Phase 8f; final_gate.sh --live can't pre-spawn them externally).
      Esr.WorkerSupervisor,

      # 4d. Session registry for CC ↔ WS bindings (PRD v0.2 §3.2).
      Esr.Resource.AdapterSocket.Registry,

      # 4d.0 Sidecar.Registry — adapter_type → python_module dispatch table.
      # Replaces WorkerSupervisor's hardcoded @sidecar_dispatch (Track 0
      # plugin work). Plugins register their sidecar mappings via manifest.
      {Esr.Resource.Sidecar.Registry, []},

      # 4d.0b Stateful Entity registry (PR-3.2): tracks which modules
      # AgentSpawner should spawn per-session vs treat as stateless
      # proxy markers. Core registers PtyProcess at boot; plugins
      # register their stateful peers via manifest `entities:` blocks
      # with `kind: stateful`. Started before Esr.Entity.Agent.Registry
      # which AgentSpawner already depends on.
      {Esr.Entity.Agent.StatefulRegistry, []},

      # 4d.1 Agent topology registry (R5 split from legacy SessionRegistry).
      # agents.yaml-compiled definitions cache + hot-reload. Started before
      # Scope.Admin since admin commands (e.g. session_new) validate the
      # requested agent name against this registry.
      {Esr.Entity.Agent.Registry, []},

      # 4d.2 Agent InstanceRegistry (Phase 3): per-session ETS backing the
      # multi-agent model. Single global instance — session UUID+name key
      # provides the per-session isolation. Started before Session.Registry
      # since add_agent_to_session delegates to it at write time.
      {Esr.Entity.Agent.InstanceRegistry, []},

      # 4d.3 Session.Registry (Phase 1): ETS-backed session UUID+name index
      # rebuilt from disk at boot. Wraps session.json I/O via FileLoader +
      # JsonWriter. Phase 3 adds add_agent_to_session write-through.
      {Esr.Resource.Session.Registry, []},

      # 4e.1 Session registry for the Peer/Session refactor (spec §3.5).
      # Must come BEFORE Scope.Admin (which calls Esr.Scope.supervisor_name/1
      # via Entity.Factory.spawn_peer_bootstrap/3 if it ever spawns admin-scope
      # peers via Session.supervisor_name) and before Scope.Supervisor.
      {Registry, keys: :unique, name: Esr.Scope.Registry},

      # 4e.2 Scope.Admin — permanent supervisor hosting admin-scope peers.
      # Risk F: started BEFORE Scope.Router (not in PR-2 yet) and BEFORE
      # Scope.Supervisor.
      Esr.Scope.Admin,

      # 4e.3 Scope.Supervisor (DynamicSupervisor, max_children=128).
      Esr.Scope.Supervisor,

      # 4e.3b ChatScope.Registry (R5 split from legacy SessionRegistry):
      # `(chat_id, app_id) → session_id` chat-current routing + URI-claim
      # uniqueness indexes. Started just before Scope.Router since the
      # router is the primary writer (register_session on success path,
      # unregister_session on session end) and FeishuAppAdapter / admin
      # commands are the primary readers.
      {Esr.Resource.ChatScope.Registry, []},

      # 4e.4 Scope.Router (PR-8 T4): control-plane GenServer that
      # `Session.New` and Feishu adapters dispatch through to spawn
      # the agents.yaml pipeline. Depends on ChatScope.Registry,
      # Scope.Supervisor, and Session.Registry (all earlier
      # children). Without this, production `/new-session` calls
      # fail with :noproc even though tests pass via start_supervised.
      Esr.Scope.Router,

      # 4d.5 Workspace name↔id index — must come before Workspace.Registry
      # since Registry calls into NameIndex on every put/rename/delete.
      {Esr.Resource.Workspace.NameIndex, []},

      # 4e. Workspaces registry (PRD v0.2 §3.6).
      Esr.Resource.Workspace.Registry,

      # 4e.1 First-boot tasks: delete legacy workspaces.yaml + ensure
      # default workspace. restart=:transient — Task exits :ok on success.
      Esr.Resource.Workspace.Bootstrap,

      # 4e.2 SlashRouteRegistry subsystem (PR-21κ 2026-04-30) — yaml-driven
      # slash command routing + dispatcher kind→{permission, command_module}
      # lookup. Independent of Workspaces and Capabilities (stores
      # references to caps as strings; doesn't validate against Permissions
      # Registry). Loaded BEFORE Admin.Supervisor since Dispatcher consumes it.
      Esr.Resource.SlashRoute.Registry,
      {Esr.Resource.SlashRoute.Registry.Watcher, path: Esr.Paths.slash_routes_yaml()},

      # 4f. Capabilities subsystem — Permissions Registry + Grants snapshot
      # + fs watcher on ~/.esrd/<instance>/capabilities.yaml
      # (capabilities spec §5.3). Must sit AFTER Workspaces.Registry so
      # FileLoader can cross-check workspace names during validation.
      Esr.Resource.Capability.Supervisor,

      # 4f.1 Users subsystem (PR-21a) — Registry (ETS) + fs watcher on
      # users.yaml. feishu_id → esr-username binding consumed by inbound
      # envelope construction (PR-21b will wire callers). Independent of
      # Workspaces / Capabilities; ordering is informational only.
      Esr.Entity.User.Supervisor,

      # 4f.2 PendingActionsGuard (PR-21e) — TTL state machine for two-step
      # destructive confirms (D12/D15). Inbound message interception
      # is wired in feishu_app_adapter; no other dependencies.
      EsrWeb.PendingActionsGuard,

      # 4f.3 Inbound onboarding guards (PR-21w). Both extracted from
      # `Esr.Entity.FeishuAppAdapter` per `docs/notes/actor-role-vocabulary.md`
      # migration plan. Each owns its own per-key rate-limit Map and
      # exposes a single `check/3` entry point the FAA `handle_upstream`
      # path consults before further routing.
      Esr.Entity.UnboundChatGuard,
      Esr.Entity.UnboundUserGuard,

      # 4f.4 Lane B inbound capability guard (PR-21x). Extracted from
      # `Esr.Entity.Server.handle_info({:inbound_event, _})` + FAA's
      # `{:dispatch_deny_dm}` rate-limit. Owns the per-principal deny-DM
      # rate-limit Map; Entity.Server calls `CapGuard.check_inbound/3`
      # before invoking the handler. On deny, CapGuard emits telemetry
      # and dispatches an `{:outbound, ...}` to the source FAA peer.
      Esr.Entity.CapGuard,

      # 4g.0 Slash subsystem — CleanupRendezvous (PR-2.3a). Tracks
      # session_id → task_pid for `/end-session` Tasks blocking on
      # MCP-side `session.signal_cleanup` ack. Started BEFORE
      # Esr.Slash.Supervisor so callsites in BranchEnd / Server can
      # find it during the same boot pass. Runs in parallel to the
      # legacy Dispatcher path until PR-2.3b deletes Dispatcher.
      Esr.Slash.CleanupRendezvous,

      # 4g.1 SlashHandler bootstrap (PR-2.3b-2). One-shot init child
      # whose `init/1` brings up SlashHandler under Scope.Admin's
      # children sup, then returns :ignore. Placed BEFORE
      # Esr.Slash.Supervisor so the Watcher's dispatch of pending
      # orphans at boot lands on a live :slash_handler peer.
      Esr.Slash.HandlerBootstrap,

      # 4g. Admin subsystem — Dispatcher + CommandQueue.Watcher
      # (dev-prod-isolation spec §6.1). Sits AFTER Capabilities
      # (Dispatcher checks grants during authorization) and AFTER
      # Workspaces.Registry (register_adapter validates workspace
      # names). Watcher's init mkdir_p's the admin_queue/ subdirs.
      Esr.Slash.Supervisor,

      # 4h. Routing subsystem (P3-14): Esr.Routing.Supervisor +
      # Esr.Routing.SlashHandler removed. The new slash-parsing path
      # is Esr.Entity.SlashHandler, spawned per-Session under
      # Scope.Admin.Process / Scope.Process (spec §3.5). The old
      # top-level subsystem was PR-0 scaffolding that got stranded
      # once the peer/session refactor moved slash parsing into the
      # peer graph.

      # 5. Subsystem supervisors (scaffolds in F02; children arrive per-FR).
      # (P2-16) Esr.AdapterHub.Supervisor removed — AdapterHub.Registry's
      # role (adapter:<name>/<instance_id> → actor_id binding) is subsumed
      # by Esr.Resource.ChatScope.Registry.lookup_by_chat/2 in the new
      # peer chain (post-R5).
      Esr.HandlerRouter.Supervisor,
      Esr.Persistence.Supervisor,
      Esr.Telemetry.Supervisor,

      # 6. Web endpoint last — ready to serve channels once everything above is up.
      EsrWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Esr.Supervisor]
    result = Supervisor.start_link(children, opts)

    # P4a-7: bring up the voice pools under Scope.Admin's children
    # supervisor. Must happen after Supervisor.start_link/2 because the
    # bootstrap resolves the `Scope.Admin.ChildrenSupervisor` via its
    # registered name. Failures are logged but non-fatal — the rest of
    # the tree keeps running with voice paths degraded.
    #
    # PR-8 T1: also bring up the admin-scope SlashHandler so
    # `FeishuChatProxy` has a peer to forward `:slash_cmd` to. Same
    # non-fatal policy — a missing SlashHandler degrades the slash
    # command path, not the rest of the tree.
    case result do
      {:ok, _} ->
        # PR-3.1: fallback sidecar mappings (feishu/cc_mcp) removed.
        # `Esr.Plugin.Loader` registers them from the plugin manifests
        # (`runtime/lib/esr/plugins/{feishu,claude_code}/manifest.yaml`)
        # via `load_enabled_plugins/0` below. Default-enabled list
        # (when no operator plugins.yaml exists) is `["feishu",
        # "claude_code"]` per `Esr.Plugin.EnabledList`.

        # Phase D-1 (2026-05-05): only `Esr.Entity.PtyProcess` is
        # genuinely core-shipped. All plugin stateful peers
        # (FeishuChatProxy / FeishuAppAdapter / CCProcess) are now
        # registered by `Esr.Plugin.Loader.register_entities/1` from
        # the manifests of enabled plugins. Pre-Phase-D-1 those three
        # were ALSO hardcoded here as "transitional fallbacks" — but
        # PR-3.3/PR-3.6 had already shipped, so the fallback was dead
        # weight that contradicted the "Loader is canonical" claim.
        # See docs/notes/2026-05-05-cli-dual-rail.md for the dual-rail
        # discipline that surfaced this gap; the corrected status doc
        # at docs/notes/2026-05-05-phase-3-4-status.md (zh_cn parallel)
        # called it out explicitly.
        :ok = Esr.Entity.Agent.StatefulRegistry.register(Esr.Entity.PtyProcess)

        # PR-2.3b-2: SlashHandler is now bootstrapped via the
        # Esr.Slash.HandlerBootstrap supervision child (placed before
        # Esr.Slash.Supervisor so Watcher orphan-recovery lands on a
        # live peer). No post-start work needed here.

        # HR-1: create the config snapshot ETS table before loading plugins
        # so ConfigSnapshot.init/2 (called from Loader.start_plugin/2) has
        # a table to write into.
        :ok = Esr.Plugin.ConfigSnapshot.create_table()

        # Plugin loader (Track 0 Task 0.4). Phase 0: zero plugins on
        # disk → no-op. Once `runtime.exs` populates `:enabled_plugins`
        # (Task 0.5) and plugins materialize under
        # `runtime/lib/esr/plugins/`, this fans out to register their
        # contributions in core registries (Phase-1 covers
        # python_sidecars; capabilities/slash routes/agents follow as
        # those registries gain register/3 APIs).
        load_enabled_plugins()

      _ ->
        :ok
    end

    if Application.get_env(:esr, :restore_on_start, true) do
      # esrd_home argument retained for backward-compat with existing
      # tests; Esr.Paths.* helpers (used internally) read ESRD_HOME /
      # ESR_INSTANCE directly, so the passed value is effectively
      # advisory — set ESRD_HOME to override.
      _ = load_workspaces_from_disk(Esr.Paths.esrd_home())
      _ = load_agents_from_disk()

      # PR-21β 2026-04-30: cleanup_orphans is gone. erlexec owns
      # subprocess lifecycle — when the previous BEAM exited, all
      # workers died with it. No orphan accumulation possible.

      _ = restore_adapters_from_disk(Esr.Paths.esrd_home())

      # PR-3.4 (2026-05-05): plugin startup callbacks. Each enabled
      # plugin's manifest `startup:` block runs here in plugin-enable
      # order. feishu's startup spawns one FeishuAppAdapter per
      # `type: feishu` row in adapters.yaml — see
      # `Esr.Plugins.Feishu.Bootstrap.bootstrap/0`. No try/rescue
      # by design: a startup failure crashes esrd boot loudly rather
      # than degrading silently (the bootstrap-miss → silent-dropped-
      # frames anti-pattern PR-K/L chased).
      :ok = Esr.Plugin.Loader.run_startup()

      # PR-9 T11a: spawn a Python handler_worker for every handler
      # module referenced by any agents.yaml `capabilities_required`
      # entry. Without this, `Esr.HandlerRouter.call/3` broadcasts
      # `handler:<module>/default` envelope to an empty topic and
      # CCProcess times out waiting for a reply. This closes the
      # "nobody spawns X worker" anti-pattern structurally: every
      # handler declared in capabilities has a boot-time spawn.
      _ = restore_handlers_from_disk()
    end

    result
  end

  @doc """
  Discover plugins under `runtime/lib/esr/plugins/`, topo-sort the
  enabled subset (from `Application.get_env(:esr, :enabled_plugins)`),
  and register each plugin's contributions in core registries.

  Phase 0 default: enabled list empty → no plugins started. Failures
  are logged but non-fatal so an on-disk plugin with a bad manifest
  doesn't take down the rest of the runtime.

  Track 0 Task 0.4. Spec:
  `docs/superpowers/specs/2026-05-04-plugin-mechanism-design.md` §五.
  """
  @spec load_enabled_plugins() :: :ok
  def load_enabled_plugins do
    require Logger
    enabled = Application.get_env(:esr, :enabled_plugins, []) |> Enum.map(&to_string/1)

    with {:ok, discovered} <- Esr.Plugin.Loader.discover(),
         {:ok, ordered} <- Esr.Plugin.Loader.topo_sort_enabled(discovered, enabled) do
      for {name, manifest} <- ordered do
        case Esr.Plugin.Loader.start_plugin(name, manifest) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "plugin loader: start_plugin(#{name}) failed: #{inspect(reason)}; " <>
                "plugin will be unavailable until next restart"
            )
        end
      end

      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "plugin loader: discovery / topo-sort failed: #{inspect(reason)}; " <>
            "no plugins started"
        )

        :ok
    end
  end

  @doc """
  Load `<runtime_home>/agents.yaml` into `Esr.Entity.Agent.Registry` at
  boot. Mirrors `load_workspaces_from_disk/1` — missing file is not an
  error, parse failures are logged. Exists so e2e scenarios (which drop
  an agents.yaml at the instance root before `scripts/esrd.sh start`)
  don't have to reach into ExUnit test support to load agents manually.
  """
  @spec load_agents_from_disk() :: :ok
  def load_agents_from_disk do
    require Logger
    path = Path.join(Esr.Paths.runtime_home(), "agents.yaml")

    if File.exists?(path) do
      case Esr.Entity.Agent.Registry.load_agents(path) do
        :ok ->
          Logger.info("agents.yaml: loaded from #{path}")
          :ok

        {:error, reason} ->
          Logger.warning("agents.yaml: load failed (#{inspect(reason)}); continuing")
          :ok
      end
    else
      Logger.info("agents.yaml: absent at #{path}; skipping")
      :ok
    end
  end

  @doc """
  Load `<home>/default/workspaces.yaml` into
  `Esr.Resource.Workspace.Registry`. v0.2 uses instance="default". Missing
  file is not an error — returns :ok.
  """
  @spec load_workspaces_from_disk(Path.t()) :: :ok
  def load_workspaces_from_disk(_esrd_home) do
    path = Esr.Paths.workspaces_yaml()

    case Esr.Resource.Workspace.Registry.load_from_file(path) do
      {:ok, workspaces} ->
        for {_name, ws} <- workspaces do
          :ok = Esr.Resource.Workspace.Registry.put(ws)
        end

        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Read `<home>/default/adapters.yaml` and spawn each instance via
  `Esr.WorkerSupervisor.ensure_adapter/4`. Missing file → `:ok`.

  `opts[:spawn_fn]` is an injection point for tests; prod uses
  `ensure_adapter` via `default_adapter_ws_url/0`.
  """
  @spec restore_adapters_from_disk(Path.t(), keyword()) :: :ok
  def restore_adapters_from_disk(_esrd_home, opts \\ []) do
    spawn_fn =
      Keyword.get(opts, :spawn_fn, fn instance, type, config ->
        url = default_adapter_ws_url()

        case Esr.WorkerSupervisor.ensure_adapter(type, instance, config, url) do
          :ok -> :ok
          :already_running -> :ok
          {:error, _} = err -> err
        end
      end)

    path = Esr.Paths.adapters_yaml()

    if File.exists?(path) do
      with {:ok, parsed} <- YamlElixir.read_from_file(path),
           instances when is_map(instances) <- parsed["instances"] || %{} do
        for {name, row} <- instances do
          type = row["type"] || ""
          config = row["config"] || %{}
          _ = spawn_fn.(name, type, config)
          # Topology auto-restore of feishu-app-session peers was deleted
          # in P3-13 (Topology module removal). In the peer/session
          # refactor, FeishuAppAdapter peers are started via
          # adapters.yaml + WorkerSupervisor above; no separate Elixir
          # peer needs to be auto-spawned per app_id.
        end
      end
    end

    :ok
  end

  defp default_adapter_ws_url, do: ws_url_for("/adapter_hub/socket")

  defp default_handler_ws_url, do: ws_url_for("/handler_hub/socket")

  defp ws_url_for(socket_path) do
    port =
      case EsrWeb.Endpoint.config(:http) do
        opts when is_list(opts) -> Keyword.get(opts, :port, 4001)
        _ -> 4001
      end

    "ws://127.0.0.1:" <> Integer.to_string(port) <> socket_path <> "/websocket?vsn=2.0.0"
  end

  @doc """
  Read `<runtime_home>/agents.yaml` and ensure a Python handler_worker
  subprocess is running for every handler module referenced by any
  agent's `capabilities_required` list.

  Capability strings follow `handler:<module>/<action>` (spec §5.3);
  this function extracts the `<module>` segment, deduplicates, and
  calls `Esr.WorkerSupervisor.ensure_handler(module, "default", url)`
  for each. `worker_id="default"` matches the single-worker-per-module
  v0.1 convention already assumed by `Esr.HandlerRouter.call/3`.

  Missing agents.yaml → `:ok` (nothing to bootstrap). Spawn failures
  are logged but non-fatal so the rest of the runtime stays up with a
  degraded handler plane — mirrors the policy of
  `bootstrap_feishu_app_adapters/0` and `bootstrap_slash_handler/0`.

  PR-9 T11a. Addresses the "nobody spawns handler worker"
  anti-pattern structurally: every handler declared as a capability
  requirement gets a boot-time spawn.
  """
  @spec restore_handlers_from_disk(keyword()) :: :ok
  def restore_handlers_from_disk(opts \\ []) do
    require Logger

    spawn_fn =
      Keyword.get(opts, :spawn_fn, fn module ->
        case Esr.WorkerSupervisor.ensure_handler(module, "default", default_handler_ws_url()) do
          :ok -> :ok
          :already_running -> :ok
          {:error, _} = err -> err
        end
      end)

    path = Path.join(Esr.Paths.runtime_home(), "agents.yaml")

    modules =
      if File.exists?(path) do
        extract_handler_modules(path)
      else
        []
      end

    for mod <- modules do
      case spawn_fn.(mod) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "handler bootstrap: ensure_handler failed module=#{inspect(mod)} " <>
              "reason=#{inspect(reason)}; handler calls to this module will time out"
          )
      end
    end

    :ok
  end

  # Parse agents.yaml and return the sorted-unique list of handler
  # module names referenced by any `capabilities_required` entry shaped
  # `"handler:<module>/<action>"`. Malformed capabilities (unknown
  # prefix, missing slash) are silently skipped — the
  # `Esr.Resource.Capability.Grants` validator catches schema errors at grant
  # time; this pass only cares about the well-formed handler refs.
  @spec extract_handler_modules(Path.t()) :: [String.t()]
  def extract_handler_modules(agents_yaml_path) do
    with {:ok, content} <- File.read(agents_yaml_path),
         {:ok, parsed} <- YamlElixir.read_from_string(content) do
      agents = parsed["agents"] || %{}

      agents
      |> Map.values()
      |> Enum.flat_map(&(&1["capabilities_required"] || []))
      |> Enum.flat_map(&handler_module_from_capability/1)
      |> Enum.uniq()
      |> Enum.sort()
    else
      _ -> []
    end
  end

  defp handler_module_from_capability("handler:" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [mod, _action] when mod != "" -> [mod]
      _ -> []
    end
  end

  defp handler_module_from_capability(_), do: []

  @impl Application
  def config_change(changed, _new, removed) do
    EsrWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

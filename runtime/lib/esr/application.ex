defmodule Esr.Application do
  @moduledoc """
  OTP Application entry. Starts the supervision tree declared in
  `docs/superpowers/specs/2026-04-18-esr-extraction-design.md` §3.1.

  Child order matters: PubSub and PeerRegistry must be up before any
  PeerServer or adapter/handler subsystem can register itself.

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

      # 3. Actor registry before any PeerServer can register itself.
      {Registry, keys: :unique, name: Esr.PeerRegistry},

      # 4. Dynamic supervisor that hosts live PeerServers.
      Esr.PeerSupervisor,

      # 4b. Dead-letter queue — started before peers so enqueue never misses.
      {Esr.DeadLetter, name: Esr.DeadLetter},

      # 4c. Python worker launcher — on-demand adapter_runner /
      # handler_worker subprocesses for live topology instantiation
      # (Phase 8f; final_gate.sh --live can't pre-spawn them externally).
      Esr.WorkerSupervisor,

      # 4d. Session registry for CC ↔ WS bindings (PRD v0.2 §3.2).
      Esr.AdapterSocketRegistry,
      {Esr.SessionRegistry, []},

      # 4e.1 Session registry for the Peer/Session refactor (spec §3.5).
      # Must come BEFORE Scope.Admin (which calls Esr.Scope.supervisor_name/1
      # via PeerFactory.spawn_peer_bootstrap/4 if it ever spawns admin-scope
      # peers via Session.supervisor_name) and before Scope.Supervisor.
      {Registry, keys: :unique, name: Esr.Scope.Registry},

      # 4e.2 Scope.Admin — permanent supervisor hosting admin-scope peers.
      # Risk F: started BEFORE Scope.Router (not in PR-2 yet) and BEFORE
      # Scope.Supervisor.
      Esr.Scope.Admin,

      # 4e.3 Scope.Supervisor (DynamicSupervisor, max_children=128).
      Esr.Scope.Supervisor,

      # 4e.4 Scope.Router (PR-8 T4): control-plane GenServer that
      # `Session.New` and Feishu adapters dispatch through to spawn
      # the agents.yaml pipeline. Depends on SessionRegistry,
      # Scope.Supervisor, and Session.Registry (all earlier
      # children). Without this, production `/new-session` calls
      # fail with :noproc even though tests pass via start_supervised.
      Esr.Scope.Router,

      # 4e. Workspaces registry (PRD v0.2 §3.6).
      Esr.Workspaces.Registry,

      # 4e.1 Workspaces fs watcher (PR-C 2026-04-27 actor-topology-routing
      # §6.1 + §7). Loads workspaces.yaml on init + reloads on file_event,
      # broadcasting `{:topology_neighbour_added, ws, uri}` via
      # `EsrWeb.PubSub` so active CC peers can grow their reachable_set
      # without restarting. Must sit AFTER Workspaces.Registry; the
      # watcher reuses Registry's ETS table.
      {Esr.Workspaces.Watcher, path: Esr.Paths.workspaces_yaml()},

      # 4e.2 SlashRoutes subsystem (PR-21κ 2026-04-30) — yaml-driven
      # slash command routing + dispatcher kind→{permission, command_module}
      # lookup. Independent of Workspaces and Capabilities (stores
      # references to caps as strings; doesn't validate against Permissions
      # Registry). Loaded BEFORE Admin.Supervisor since Dispatcher consumes it.
      Esr.SlashRoutes,
      {Esr.SlashRoutes.Watcher, path: Esr.Paths.slash_routes_yaml()},

      # 4f. Capabilities subsystem — Permissions Registry + Grants snapshot
      # + fs watcher on ~/.esrd/<instance>/capabilities.yaml
      # (capabilities spec §5.3). Must sit AFTER Workspaces.Registry so
      # FileLoader can cross-check workspace names during validation.
      Esr.Capabilities.Supervisor,

      # 4f.1 Users subsystem (PR-21a) — Registry (ETS) + fs watcher on
      # users.yaml. feishu_id → esr-username binding consumed by inbound
      # envelope construction (PR-21b will wire callers). Independent of
      # Workspaces / Capabilities; ordering is informational only.
      Esr.Users.Supervisor,

      # 4f.2 PendingActionsGuard (PR-21e) — TTL state machine for two-step
      # destructive confirms (D12/D15). Inbound message interception
      # is wired in feishu_app_adapter; no other dependencies.
      EsrWeb.PendingActionsGuard,

      # 4f.3 Inbound onboarding guards (PR-21w). Both extracted from
      # `Esr.Peers.FeishuAppAdapter` per `docs/notes/actor-role-vocabulary.md`
      # migration plan. Each owns its own per-key rate-limit Map and
      # exposes a single `check/3` entry point the FAA `handle_upstream`
      # path consults before further routing.
      Esr.Peers.UnboundChatGuard,
      Esr.Peers.UnboundUserGuard,

      # 4f.4 Lane B inbound capability guard (PR-21x). Extracted from
      # `Esr.PeerServer.handle_info({:inbound_event, _})` + FAA's
      # `{:dispatch_deny_dm}` rate-limit. Owns the per-principal deny-DM
      # rate-limit Map; PeerServer calls `CapGuard.check_inbound/3`
      # before invoking the handler. On deny, CapGuard emits telemetry
      # and dispatches an `{:outbound, ...}` to the source FAA peer.
      Esr.Peers.CapGuard,

      # 4g. Admin subsystem — Dispatcher + CommandQueue.Watcher
      # (dev-prod-isolation spec §6.1). Sits AFTER Capabilities
      # (Dispatcher checks grants during authorization) and AFTER
      # Workspaces.Registry (register_adapter validates workspace
      # names). Watcher's init mkdir_p's the admin_queue/ subdirs.
      Esr.Admin.Supervisor,

      # 4h. Routing subsystem (P3-14): Esr.Routing.Supervisor +
      # Esr.Routing.SlashHandler removed. The new slash-parsing path
      # is Esr.Peers.SlashHandler, spawned per-Session under
      # Scope.Admin.Process / Scope.Process (spec §3.5). The old
      # top-level subsystem was PR-0 scaffolding that got stranded
      # once the peer/session refactor moved slash parsing into the
      # peer graph.

      # 5. Subsystem supervisors (scaffolds in F02; children arrive per-FR).
      # (P2-16) Esr.AdapterHub.Supervisor removed — AdapterHub.Registry's
      # role (adapter:<name>/<instance_id> → actor_id binding) is subsumed
      # by Esr.SessionRegistry.lookup_by_chat_thread/3 in the new peer chain.
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
        case Esr.Scope.Admin.bootstrap_voice_pools(Esr.Paths.pools_yaml()) do
          :ok ->
            :ok

          {:error, reason} ->
            require Logger

            Logger.warning(
              "admin_session: bootstrap_voice_pools failed: #{inspect(reason)}; " <>
                "voice peers will be unavailable until restart"
            )
        end

        case Esr.Scope.Admin.bootstrap_slash_handler() do
          :ok ->
            :ok

          {:error, reason} ->
            require Logger

            Logger.warning(
              "admin_session: bootstrap_slash_handler failed: #{inspect(reason)}; " <>
                "slash commands will be unavailable until restart"
            )
        end

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

      # PR-9 T10: spawn one FeishuAppAdapter (Elixir admin peer) per
      # `type: feishu` instance in adapters.yaml. Must come AFTER
      # restore_adapters_from_disk so the Python sidecar and the Elixir
      # consumer are both up by the time anything pushes inbound. Without
      # this, adapter_channel logs "no FeishuAppAdapter for app_id=..."
      # and every inbound frame is silently dropped.
      _ = Esr.Scope.Admin.bootstrap_feishu_app_adapters()

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
  Load `<runtime_home>/agents.yaml` into `Esr.SessionRegistry` at boot.
  Mirrors `load_workspaces_from_disk/1` — missing file is not an error,
  parse failures are logged. Exists so e2e scenarios (which drop an
  agents.yaml at the instance root before `scripts/esrd.sh start`) don't
  have to reach into ExUnit test support to load agents manually.
  """
  @spec load_agents_from_disk() :: :ok
  def load_agents_from_disk do
    require Logger
    path = Path.join(Esr.Paths.runtime_home(), "agents.yaml")

    if File.exists?(path) do
      case Esr.SessionRegistry.load_agents(path) do
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
  `Esr.Workspaces.Registry`. v0.2 uses instance="default". Missing
  file is not an error — returns :ok.
  """
  @spec load_workspaces_from_disk(Path.t()) :: :ok
  def load_workspaces_from_disk(_esrd_home) do
    path = Esr.Paths.workspaces_yaml()

    case Esr.Workspaces.Registry.load_from_file(path) do
      {:ok, workspaces} ->
        for {_name, ws} <- workspaces do
          :ok = Esr.Workspaces.Registry.put(ws)
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
  # `Esr.Capabilities.Grants` validator catches schema errors at grant
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

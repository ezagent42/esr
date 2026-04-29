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
    apply_tmux_socket_env()

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
      Esr.SessionSocketRegistry,
      {Esr.SessionRegistry, []},

      # 4e.1 Session registry for the Peer/Session refactor (spec §3.5).
      # Must come BEFORE AdminSession (which calls Esr.Session.supervisor_name/1
      # via PeerFactory.spawn_peer_bootstrap/4 if it ever spawns admin-scope
      # peers via Session.supervisor_name) and before SessionsSupervisor.
      {Registry, keys: :unique, name: Esr.Session.Registry},

      # 4e.2 AdminSession — permanent supervisor hosting admin-scope peers.
      # Risk F: started BEFORE SessionRouter (not in PR-2 yet) and BEFORE
      # SessionsSupervisor.
      Esr.AdminSession,

      # 4e.3 SessionsSupervisor (DynamicSupervisor, max_children=128).
      Esr.SessionsSupervisor,

      # 4e.4 SessionRouter (PR-8 T4): control-plane GenServer that
      # `Session.New` and Feishu adapters dispatch through to spawn
      # the agents.yaml pipeline. Depends on SessionRegistry,
      # SessionsSupervisor, and Session.Registry (all earlier
      # children). Without this, production `/new-session` calls
      # fail with :noproc even though tests pass via start_supervised.
      Esr.SessionRouter,

      # 4e. Workspaces registry (PRD v0.2 §3.6).
      Esr.Workspaces.Registry,

      # 4e.1 Workspaces fs watcher (PR-C 2026-04-27 actor-topology-routing
      # §6.1 + §7). Loads workspaces.yaml on init + reloads on file_event,
      # broadcasting `{:topology_neighbour_added, ws, uri}` via
      # `EsrWeb.PubSub` so active CC peers can grow their reachable_set
      # without restarting. Must sit AFTER Workspaces.Registry; the
      # watcher reuses Registry's ETS table.
      {Esr.Workspaces.Watcher, path: Esr.Paths.workspaces_yaml()},

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

      # 4f.2 PendingActions (PR-21e) — TTL state machine for two-step
      # destructive confirms (D12/D15). Inbound message interception
      # is wired in feishu_app_adapter; no other dependencies.
      EsrWeb.PendingActions,

      # 4g. Admin subsystem — Dispatcher + CommandQueue.Watcher
      # (dev-prod-isolation spec §6.1). Sits AFTER Capabilities
      # (Dispatcher checks grants during authorization) and AFTER
      # Workspaces.Registry (register_adapter validates workspace
      # names). Watcher's init mkdir_p's the admin_queue/ subdirs.
      Esr.Admin.Supervisor,

      # 4h. Routing subsystem (P3-14): Esr.Routing.Supervisor +
      # Esr.Routing.SlashHandler removed. The new slash-parsing path
      # is Esr.Peers.SlashHandler, spawned per-Session under
      # AdminSessionProcess / SessionProcess (spec §3.5). The old
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

    # P4a-7: bring up the voice pools under AdminSession's children
    # supervisor. Must happen after Supervisor.start_link/2 because the
    # bootstrap resolves the `AdminSession.ChildrenSupervisor` via its
    # registered name. Failures are logged but non-fatal — the rest of
    # the tree keeps running with voice paths degraded.
    #
    # PR-8 T1: also bring up the admin-scope SlashHandler so
    # `FeishuChatProxy` has a peer to forward `:slash_cmd` to. Same
    # non-fatal policy — a missing SlashHandler degrades the slash
    # command path, not the rest of the tree.
    case result do
      {:ok, _} ->
        case Esr.AdminSession.bootstrap_voice_pools(Esr.Paths.pools_yaml()) do
          :ok ->
            :ok

          {:error, reason} ->
            require Logger

            Logger.warning(
              "admin_session: bootstrap_voice_pools failed: #{inspect(reason)}; " <>
                "voice peers will be unavailable until restart"
            )
        end

        case Esr.AdminSession.bootstrap_slash_handler() do
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

      # PR-21m (2026-04-29): clean up orphan subprocesses BEFORE
      # restore_adapters_from_disk re-spawns them. Origin: BEAM
      # crashes during PR-21 dev cycles re-parented subprocesses to
      # launchd (PID 1) — they outlived their parent esrd, kept
      # holding Feishu app credentials, and produced silent message-
      # loss when restore_adapters spawned a new sibling. The
      # boot-time sweep ensures the new generation owns the Feishu
      # WS without contention.
      try do
        stats = Esr.WorkerSupervisor.cleanup_orphans()
        require Logger

        Logger.info(
          "WorkerSupervisor.cleanup_orphans at boot: " <>
            "checked=#{stats.checked} orphans_killed=#{stats.orphans_killed} " <>
            "stale_unlinked=#{stats.stale_unlinked}"
        )
      catch
        kind, reason ->
          require Logger

          Logger.warning(
            "WorkerSupervisor.cleanup_orphans failed (#{kind}: #{inspect(reason)}); " <>
              "continuing boot"
          )
      end

      _ = restore_adapters_from_disk(Esr.Paths.esrd_home())

      # PR-9 T10: spawn one FeishuAppAdapter (Elixir admin peer) per
      # `type: feishu` instance in adapters.yaml. Must come AFTER
      # restore_adapters_from_disk so the Python sidecar and the Elixir
      # consumer are both up by the time anything pushes inbound. Without
      # this, adapter_channel logs "no FeishuAppAdapter for app_id=..."
      # and every inbound frame is silently dropped.
      _ = Esr.AdminSession.bootstrap_feishu_app_adapters()

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
  Read tmux socket path env vars and, when set to a non-empty value,
  stash under `{:esr, :tmux_socket_override}`. TmuxProcess.spawn_args/1
  consults the override when its caller didn't supply `:tmux_socket`.

  Two env vars are honoured (first non-empty wins):

  * `ESR_E2E_TMUX_SOCK` — set by E2E scenarios for per-run isolation.
  * `ESR_TMUX_SOCKET`   — set by the prod/dev LaunchAgent plists so the
    two esrds don't share `/tmp/tmux-$UID/default`. Operators attach
    via `tmux -S $ESRD_HOME/default/tmux.sock attach -t esr_cc_<N>`.

  Exposed publicly for test access — pure function; idempotent.
  """
  @spec apply_tmux_socket_env() :: :ok
  def apply_tmux_socket_env do
    e2e = System.get_env("ESR_E2E_TMUX_SOCK")
    plist = System.get_env("ESR_TMUX_SOCKET")

    case e2e || plist do
      nil -> :ok
      "" -> :ok
      path -> Application.put_env(:esr, :tmux_socket_override, path)
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

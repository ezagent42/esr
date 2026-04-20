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
      Esr.SessionRegistry,

      # 4e. Workspaces registry (PRD v0.2 §3.6).
      Esr.Workspaces.Registry,

      # 5. Subsystem supervisors (scaffolds in F02; children arrive per-FR).
      Esr.AdapterHub.Supervisor,
      Esr.HandlerRouter.Supervisor,
      Esr.Topology.Supervisor,
      Esr.Persistence.Supervisor,
      Esr.Telemetry.Supervisor,

      # 6. Web endpoint last — ready to serve channels once everything above is up.
      EsrWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Esr.Supervisor]
    result = Supervisor.start_link(children, opts)

    if Application.get_env(:esr, :restore_on_start, true) do
      esrd_home =
        System.get_env("ESRD_HOME", Path.join(System.user_home!(), ".esrd"))

      _ = load_workspaces_from_disk(esrd_home)
      _ = restore_adapters_from_disk(esrd_home)
    end

    result
  end

  @doc """
  Load `<home>/default/workspaces.yaml` into
  `Esr.Workspaces.Registry`. v0.2 uses instance="default". Missing
  file is not an error — returns :ok.
  """
  @spec load_workspaces_from_disk(Path.t()) :: :ok
  def load_workspaces_from_disk(esrd_home) do
    path = Path.join([esrd_home, "default", "workspaces.yaml"])

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
  def restore_adapters_from_disk(esrd_home, opts \\ []) do
    spawn_fn =
      Keyword.get(opts, :spawn_fn, fn instance, type, config ->
        url = default_adapter_ws_url()

        case Esr.WorkerSupervisor.ensure_adapter(type, instance, config, url) do
          :ok -> :ok
          :already_running -> :ok
          {:error, _} = err -> err
        end
      end)

    path = Path.join([esrd_home, "default", "adapters.yaml"])

    if File.exists?(path) do
      with {:ok, parsed} <- YamlElixir.read_from_file(path),
           instances when is_map(instances) <- parsed["instances"] || %{} do
        for {name, row} <- instances do
          type = row["type"] || ""
          config = row["config"] || %{}
          _ = spawn_fn.(name, type, config)
        end
      end
    end

    :ok
  end

  defp default_adapter_ws_url do
    port =
      case EsrWeb.Endpoint.config(:http) do
        opts when is_list(opts) -> Keyword.get(opts, :port, 4001)
        _ -> 4001
      end

    "ws://127.0.0.1:" <> Integer.to_string(port) <> "/adapter_hub/socket/websocket?vsn=2.0.0"
  end

  @impl Application
  def config_change(changed, _new, removed) do
    EsrWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

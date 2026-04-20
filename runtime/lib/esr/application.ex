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

  @impl Application
  def config_change(changed, _new, removed) do
    EsrWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

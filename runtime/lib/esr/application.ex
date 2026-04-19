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
    Supervisor.start_link(children, opts)
  end

  @impl Application
  def config_change(changed, _new, removed) do
    EsrWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

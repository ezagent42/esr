defmodule Esr.AdminSession do
  @moduledoc """
  Top-level permanent Supervisor for AdminSession — the one always-on
  Session hosting session-less peers (FeishuAppAdapter_<app_id>, SlashHandler,
  pool supervisors).

  Bootstrap exception (Risk F, spec §6): AdminSession is started directly
  by `Esr.Supervisor`, NOT by `Esr.SessionRouter` (which doesn't exist
  yet at boot; introduced in PR-3). Children of AdminSession are spawned
  via `Esr.PeerFactory.spawn_peer_bootstrap/4` which bypasses the
  SessionRouter control-plane resolution.

  See spec §3.4 and §6 Risk F.
  """
  use Supervisor

  @default_children_sup_name Esr.AdminSession.ChildrenSupervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc "Name of the DynamicSupervisor that hosts admin-scope peers."
  def children_supervisor_name(_admin_sup_name \\ __MODULE__),
    do: Application.get_env(:esr, :admin_children_sup_name, @default_children_sup_name)

  @impl true
  def init(opts) do
    children_sup_name =
      Keyword.get(opts, :children_sup_name, @default_children_sup_name)

    process_name =
      Keyword.get(opts, :process_name, Esr.AdminSessionProcess)

    # Cache the children-sup name so callers can resolve it without
    # plumbing opts through.
    Application.put_env(:esr, :admin_children_sup_name, children_sup_name)

    children = [
      # AdminSessionProcess must start before any admin-scope peer so
      # register_admin_peer/2 can record pids as peers come up.
      {Esr.AdminSessionProcess, [name: process_name]},
      # DynamicSupervisor that hosts admin-scope peers. Empty at init;
      # populated later by `bootstrap_children/0` (P2-9) or test setup.
      {DynamicSupervisor, strategy: :one_for_one, name: children_sup_name}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

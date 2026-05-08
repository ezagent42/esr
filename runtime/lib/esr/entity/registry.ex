defmodule Esr.Entity.Registry do
  @moduledoc """
  Actor-id → pid registry (PRD 01 F03). Thin wrapper over Elixir's
  Registry, which is started in the supervision tree under the same
  atom name `Esr.Entity.Registry`. Spec §3.2: PeerServers use `{:via,
  Registry, {Esr.Entity.Registry, actor_id}}` to register.

  The module name deliberately shadows the registered process name —
  callers write `Esr.Entity.Registry.lookup("cc:sess-A")` without having
  to know the underlying `Registry` module.

  ## Auxiliary indexes (M-1)

  In addition to Index 1 (actor_id → pid) backed by `Elixir.Registry`,
  this module also writes two ETS-backed indexes consulted by
  `Esr.ActorQuery`:

    * Index 2 — `:esr_actor_name_index`  : `{session_id, name} → {pid, actor_id}`
      (set; uniqueness enforced via `:ets.insert_new/2`).
    * Index 3 — `:esr_actor_role_index`  : `{session_id, role} → {pid, actor_id}`
      (bag; supports multi-instance same role per Q5.2).

  Both ETS tables are owned by `Esr.Entity.Registry.IndexWatcher`, which
  is also responsible for cleaning the indexes on monitor DOWN when a
  registered process crashes without calling `deregister_attrs/2`.
  """

  @behaviour Esr.Role.State

  @registry __MODULE__
  @name_index :esr_actor_name_index
  @role_index :esr_actor_role_index

  @doc """
  Registers `pid` under `actor_id`. Fails with `{:error, {:already_registered, _}}`
  if the key is taken by another process (the `:unique` strategy).
  """
  @spec register(String.t(), pid()) :: {:ok, pid()} | {:error, term()}
  def register(actor_id, pid) when is_binary(actor_id) and is_pid(pid) do
    # Registry.register only registers the calling pid; to register a specific
    # pid we must run the call from that pid. The common case is
    # Esr.Entity.Server.init/1 calling `register(actor_id, self())`, so the
    # calling-pid constraint is not a problem in practice.
    if pid == self() do
      case Registry.register(@registry, actor_id, nil) do
        {:ok, _owner} -> {:ok, pid}
        {:error, _} = err -> err
      end
    else
      {:error, :cannot_register_other_pid}
    end
  end

  @doc """
  Looks up the pid registered under `actor_id`. Returns `:error` if none.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(actor_id) when is_binary(actor_id) do
    case Registry.lookup(@registry, actor_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Enumerates every `{actor_id, pid}` currently registered.
  """
  @spec list_all() :: [{String.t(), pid()}]
  def list_all do
    Registry.select(@registry, [
      {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
  end

  @doc """
  Register peer attributes in Index 2 (name) and Index 3 (role).

  Must be called from the peer's own `init/1` — i.e., `self()` is the
  registrant. Returns `:ok` on success. Returns `{:error, :name_taken}`
  if `(session_id, name)` is already taken.

  A monitor is set on `self()` and tracked by
  `Esr.Entity.Registry.IndexWatcher` so the indexes are cleaned
  automatically if the process crashes without calling
  `deregister_attrs/2`.

  M-1 (additive): existing call sites (Index 1 via `register/2`) keep
  working untouched. New ActorQuery-based callers (M-2+) consult
  Index 2/3 via `Esr.ActorQuery`.
  """
  @spec register_attrs(String.t(), %{
          session_id: String.t(),
          name: String.t(),
          role: atom()
        }) :: :ok | {:error, :name_taken}
  def register_attrs(actor_id, %{session_id: sid, name: name, role: role})
      when is_binary(actor_id) and is_binary(sid) and is_binary(name) and is_atom(role) do
    pid = self()

    case :ets.insert_new(@name_index, {{sid, name}, {pid, actor_id}}) do
      true ->
        :ets.insert(@role_index, {{sid, role}, {pid, actor_id}})

        # The DOWN message is delivered to whichever process called
        # `Process.monitor/1`. We need IndexWatcher (not the registrant)
        # to receive it — when the registrant dies, anything it
        # monitored is irrelevant. So delegate the monitor setup to
        # IndexWatcher via a synchronous call: this guarantees the
        # monitor is in place before register_attrs/2 returns, ruling
        # out the race where the registrant dies between this call and
        # the watcher seeing the metadata.
        :ok =
          Esr.Entity.Registry.IndexWatcher.monitor_and_track(%{
            pid: pid,
            actor_id: actor_id,
            session_id: sid,
            name: name,
            role: role
          })

        :ok

      false ->
        {:error, :name_taken}
    end
  end

  @doc """
  Remove peer attributes from Index 2 (name) and Index 3 (role).

  Called from peer's `terminate/2`. Idempotent — safe to call even if
  the entries were already removed by the IndexWatcher's DOWN handler.
  Only removes the role-index row matching the calling pid + actor_id,
  so other peers sharing the same `{session_id, role}` (bag) bucket are
  preserved.
  """
  @spec deregister_attrs(String.t(), %{
          session_id: String.t(),
          name: String.t(),
          role: atom()
        }) :: :ok
  def deregister_attrs(actor_id, %{session_id: sid, name: name, role: role})
      when is_binary(actor_id) and is_binary(sid) and is_binary(name) and is_atom(role) do
    :ets.delete(@name_index, {sid, name})
    pid = self()
    :ets.match_delete(@role_index, {{sid, role}, {pid, actor_id}})
    :ok
  end
end

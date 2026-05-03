defmodule Esr.Entity.Registry do
  @moduledoc """
  Actor-id → pid registry (PRD 01 F03). Thin wrapper over Elixir's
  Registry, which is started in the supervision tree under the same
  atom name `Esr.Entity.Registry`. Spec §3.2: PeerServers use `{:via,
  Registry, {Esr.Entity.Registry, actor_id}}` to register.

  The module name deliberately shadows the registered process name —
  callers write `Esr.Entity.Registry.lookup("cc:sess-A")` without having
  to know the underlying `Registry` module.
  """

  @behaviour Esr.Role.State

  @registry __MODULE__

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
end

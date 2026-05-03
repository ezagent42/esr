defmodule Esr.Scope.Admin.Process do
  @moduledoc """
  Holds admin-level state: admin-scope peer refs (e.g. slash_handler pid),
  bootstrap metadata. Always registered under its own module name.

  See spec §3.4.
  """

  @behaviour Esr.Role.State
  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc "Register an admin-scope peer pid under a symbolic name."
  def register_admin_peer(name, pid) when is_atom(name) and is_pid(pid) do
    GenServer.call(__MODULE__, {:register_admin_peer, name, pid})
  end

  @doc "Return the pid for a registered admin-scope peer, or :error."
  def admin_peer(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:admin_peer, name})
  end

  @doc "Return the slash_handler pid (convenience for the §5.3 fallback)."
  def slash_handler_ref, do: admin_peer(:slash_handler)

  @doc """
  Return `[{name, pid}, ...]` for all currently registered admin peers.
  Used by legacy callers (e.g. `Esr.Admin.Commands.Notify`) that need
  to iterate to find a matching peer — post-P2-16 replacement for
  `Esr.AdapterHub.Registry.list/0`.
  """
  def list_admin_peers, do: GenServer.call(__MODULE__, :list_admin_peers)

  @impl true
  def init(_), do: {:ok, %{admin_peers: %{}}}

  @impl true
  def handle_call({:register_admin_peer, name, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, put_in(state.admin_peers[name], pid)}
  end

  def handle_call({:admin_peer, name}, _from, state) do
    case Map.fetch(state.admin_peers, name) do
      {:ok, pid} -> {:reply, {:ok, pid}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:list_admin_peers, _from, state) do
    {:reply, Enum.to_list(state.admin_peers), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, dead_pid, _reason}, state) do
    admin_peers =
      state.admin_peers
      |> Enum.reject(fn {_k, p} -> p == dead_pid end)
      |> Map.new()

    {:noreply, %{state | admin_peers: admin_peers}}
  end
end

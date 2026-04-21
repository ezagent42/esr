defmodule Esr.Capabilities.Grants do
  @moduledoc """
  ETS-backed snapshot of principal → [permission] grants.

  Loaded from `capabilities.yaml` (see `Esr.Capabilities.FileLoader`)
  and replaced atomically on reload.

  Matching rules (spec §3.3):
  - bare `*` grants everything
  - `workspace:<s>/<p>` matches when both segments match (each literally
    or via bare `*`)
  - no prefix glob — only whole-segment wildcards
  """
  use GenServer

  @table :esr_capabilities_grants

  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Replace the full snapshot atomically."
  def load_snapshot(snapshot) when is_map(snapshot) do
    GenServer.call(__MODULE__, {:load, snapshot})
  end

  @doc "Does the capability (principal_id, permission) exist?"
  def has?(principal_id, permission) when is_binary(principal_id) and is_binary(permission) do
    case :ets.lookup(@table, principal_id) do
      [] -> false
      [{^principal_id, held}] -> Enum.any?(held, &matches?(&1, permission))
    end
  end

  defp matches?("*", _required), do: true

  defp matches?(held, required) do
    with {:ok, {h_prefix, h_name, h_perm}} <- split(held),
         {:ok, {r_prefix, r_name, r_perm}} <- split(required),
         true <- h_prefix == r_prefix do
      segment_match?(h_name, r_name) and segment_match?(h_perm, r_perm)
    else
      _ -> false
    end
  end

  # Splits "workspace:<name>/<perm>" into {"workspace", "<name>", "<perm>"}.
  # The scope prefix ("workspace") must match literally; only the workspace
  # name and the permission name honour whole-segment `*` wildcards.
  defp split(str) do
    with [scope, perm] <- String.split(str, "/", parts: 2),
         [prefix, name] <- String.split(scope, ":", parts: 2) do
      {:ok, {prefix, name, perm}}
    else
      _ -> :error
    end
  end

  defp segment_match?("*", _), do: true
  defp segment_match?(a, a), do: true
  defp segment_match?(_, _), do: false

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:load, snapshot}, _from, state) do
    :ets.delete_all_objects(@table)
    Enum.each(snapshot, fn {pid, held} -> :ets.insert(@table, {pid, held}) end)
    {:reply, :ok, state}
  end
end

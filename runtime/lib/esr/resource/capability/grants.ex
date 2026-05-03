defmodule Esr.Resource.Capability.Grants do
  @moduledoc """
  ETS-backed snapshot of principal → [permission] grants.

  Loaded from `capabilities.yaml` (see `Esr.Resource.Capability.FileLoader`)
  and replaced atomically on reload.

  Matching rules (spec §3.3):
  - bare `*` grants everything
  - `workspace:<s>/<p>` matches when both segments match (each literally
    or via bare `*`)
  - no prefix glob — only whole-segment wildcards
  """

  @behaviour Esr.Role.State
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

  # PR-21s 2026-04-29: exact-string fallback for flat dotted caps like
  # `workspace.create` and `session.list`. The original split-based
  # matcher requires the `prefix:name/perm` shape and rejects flat
  # names — but Esr.Admin.permissions/0 declares both shapes (`session.list`,
  # `workspace.create`, `cap.manage`, `notify.send` are flat;
  # `session:default/create`, `session:default/end` use prefix:name/perm).
  # docs/notes/capability-name-format-mismatch.md tracks the legacy
  # spec/code drift; this fallback lets the runtime accept either form
  # without forcing a yaml schema migration.
  defp matches?(held, required) when held == required, do: true

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
    # Diff against the prior snapshot BEFORE mutating the table so
    # per-session projections only refresh when their principal's
    # grants actually changed. Without the diff, every
    # `load_snapshot/1` wakes every Scope.Process regardless of
    # whether its principal was touched — wasted work at scale, and a
    # test-isolation hazard (one test's load_snapshot spams every
    # other test's sessions).
    prior = current_snapshot()
    changed_principals = diff_changed(prior, snapshot)

    :ets.delete_all_objects(@table)
    Enum.each(snapshot, fn {pid, held} -> :ets.insert(@table, {pid, held}) end)

    broadcast_grants_changed(changed_principals)

    {:reply, :ok, state}
  end

  # --- internal ---

  defp current_snapshot do
    :ets.tab2list(@table) |> Map.new()
  rescue
    ArgumentError -> %{}
  end

  # Returns the set of principal_ids whose held-list differs between
  # the two snapshots. Uses list equality (order-sensitive) — matches
  # how `capabilities.yaml` is round-tripped, and in the rare case of
  # a reorder the extra broadcast is harmless.
  defp diff_changed(prior, new) do
    all_principals =
      MapSet.union(MapSet.new(Map.keys(prior)), MapSet.new(Map.keys(new)))

    MapSet.to_list(all_principals)
    |> Enum.filter(fn principal_id ->
      Map.get(prior, principal_id) != Map.get(new, principal_id)
    end)
  end

  defp broadcast_grants_changed(principal_ids) do
    Enum.each(principal_ids, fn principal_id ->
      Phoenix.PubSub.broadcast(
        EsrWeb.PubSub,
        "grants_changed:#{principal_id}",
        :grants_changed
      )
    end)
  end
end

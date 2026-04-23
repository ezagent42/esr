defmodule Esr.TestSupport.Grants do
  @moduledoc """
  Shared ExUnit setup helper for tests that need to grant test
  principals capabilities without leaking the grant into sibling
  tests. Snapshots the current `Esr.Capabilities.Grants` ETS table,
  merges the requested grants on top, and registers an `on_exit`
  that restores the prior snapshot.

  Usage:

      # One principal, wildcard grants (the common case).
      setup do
        Esr.TestSupport.Grants.with_principal_wildcard("ou_alice")
      end

      # Multiple principals / non-wildcard grants.
      setup do
        Esr.TestSupport.Grants.with_grants(%{
          "ou_alice" => ["*"],
          "ou_bob" => ["*"]
        })
      end

  The helpers return `:ok` so they compose with other setup blocks.

  Why read ETS directly rather than use a `snapshot/0` API on
  `Esr.Capabilities.Grants`? The GenServer doesn't expose one — every
  integration test currently reaches into `:esr_capabilities_grants`
  with `:ets.tab2list/1` to preserve prior state. Consolidating that
  convention here keeps the pattern in one place; if a public
  snapshot API is ever added, this helper is the only caller to
  update.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @table :esr_capabilities_grants

  @doc """
  Grant `principal_id` the wildcard `"*"` capability for the
  duration of the test; restore the prior snapshot on exit.
  """
  @spec with_principal_wildcard(String.t()) :: :ok
  def with_principal_wildcard(principal_id) when is_binary(principal_id) do
    with_grants(%{principal_id => ["*"]})
  end

  @doc """
  Merge `grants` (a map of `principal_id => held_list`) onto the
  current grants snapshot; restore the prior snapshot on exit.

  `held_list` follows the same shape `Esr.Capabilities.Grants`
  stores in ETS — a list of permission strings, or `["*"]` for
  wildcard, or `[]` for an intentionally empty grant (e.g. to
  exercise the unauthorized branch).
  """
  @spec with_grants(%{optional(String.t()) => [String.t()]}) :: :ok
  def with_grants(grants) when is_map(grants) do
    prior = snapshot()
    :ok = Esr.Capabilities.Grants.load_snapshot(Map.merge(prior, grants))
    on_exit(fn -> Esr.Capabilities.Grants.load_snapshot(prior) end)
    :ok
  end

  @doc """
  Snapshot the current Grants ETS table as a map. Returns `%{}` if
  the table has not been created yet (e.g. the GenServer never
  booted in this test env).
  """
  @spec snapshot() :: %{optional(String.t()) => [String.t()]}
  def snapshot do
    :ets.tab2list(@table) |> Map.new()
  rescue
    ArgumentError -> %{}
  end
end

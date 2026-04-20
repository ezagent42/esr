defmodule Esr.TestSupport.AuthContext do
  @moduledoc """
  Shared helper for loading capability grants into the app-level
  `Esr.Capabilities.Grants` ETS snapshot during tests.

  CAP-4 flips Lane B enforcement ON: `{:inbound_event, ...}` and
  `{:tool_invoke, ..., principal_id}` both check grants before
  dispatching. Tests that used to send these messages with a bare
  `principal_id` (or none at all) now need an explicit grant or the
  enforcement path will deny them.

  Typical usage:

      setup do
        Esr.TestSupport.AuthContext.load_admin("test_admin")
        :ok
      end

  Then pass `principal_id: "test_admin"` wherever the test exercises
  either Lane B entry point.

  `load_admin/1` replaces the full snapshot (mirrors
  `Grants.load_snapshot/1` semantics) so calling it twice in one test
  run is safe — the last call wins. Pair with `clear/0` if you need a
  fresh slate mid-test.
  """

  alias Esr.Capabilities.Grants

  @doc """
  Load a single admin grant (`principal_id => ["*"]`) into the
  app-level `Grants` snapshot. Returns the principal_id for pipeline
  convenience.
  """
  @spec load_admin(String.t()) :: String.t()
  def load_admin(principal_id) when is_binary(principal_id) do
    :ok = Grants.load_snapshot(%{principal_id => ["*"]})
    principal_id
  end

  @doc """
  Load an arbitrary snapshot (see `Grants.load_snapshot/1` for
  semantics). Useful when a test needs mixed grants — admin +
  scoped user + unauth user in one scenario.
  """
  @spec load(map()) :: :ok
  def load(snapshot) when is_map(snapshot) do
    Grants.load_snapshot(snapshot)
  end

  @doc """
  Clear all grants. Equivalent to `load(%{})` but reads more clearly
  at call sites that want to reset between `test` blocks.
  """
  @spec clear() :: :ok
  def clear, do: load(%{})
end

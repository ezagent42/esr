defmodule Esr.Resource.Session.Id do
  @moduledoc """
  Single source for minting session_id values.

  All session_id minting goes through `new/0` so the Phase 5 D2
  contract (session ids must be UUID v4 — cap routing validates the
  format) lives in one place. Centralizes the mint so a future
  strategy change (e.g. UUID v7 for time-ordering, or a deterministic
  test mode) touches one file.

  Pre-2026-05-09 the three call sites
  (`Esr.Commands.Session.New`, `Esr.Uri.Compat.create_session/2`,
  `Esr.Session.AgentSpawner`) each held a private `defp gen_id` /
  `defp generate_uuid` and a duplicate "Phase 5 D2: must be UUID v4"
  comment. Surfaced during Phase F (resource-typed grammar) e2e
  validation; closed by the same docs sweep that flagged it.
  """

  @doc "Mint a fresh session_id (UUID v4 string)."
  @spec new() :: String.t()
  def new, do: UUID.uuid4()
end

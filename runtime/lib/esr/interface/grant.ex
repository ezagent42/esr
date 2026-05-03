defmodule Esr.Interface.Grant do
  @moduledoc """
  Capability grant contract: any module that brokers the grant
  relationship between principals and capabilities (creating, revoking,
  checking) implements this Interface.

  Per session.md §六 Capability:
  > Two-state Resource:
  > - **Declarative**: cap is declared in code (see `Esr.Interface.CapabilityDeclaration`)
  > - **Granted**: grant relationship lives in CapabilityRegistry

  This Interface is the *granted* face.

  Current implementer (post-R9):
    - `Esr.Resource.Capability.Grants` — has `has?/2` (check) and
      `load_snapshot/1` (bulk grant via yaml). The `grant/2` and
      `revoke/2` callbacks are aspirational — today, grants flow
      through editing `capabilities.yaml` + a watcher reloading the
      snapshot. A future PR may add explicit imperative grant/revoke
      APIs (e.g. for plugin-installed capabilities).

  Until that future PR, this Interface declares the metamodel contract
  but `Esr.Resource.Capability.Grants` does NOT yet declare
  `@behaviour Esr.Interface.Grant` — the API doesn't fully match.

  See session.md §七 (GrantInterface) and
  `docs/notes/structural-refactor-plan-r4-r11.md` §四-R9.
  """

  @doc "Grant `permission` to `principal_id`. Returns `:ok` or `{:error, reason}`."
  @callback grant(principal_id :: String.t(), permission :: String.t()) ::
              :ok | {:error, term()}

  @doc "Revoke `permission` from `principal_id`. Returns `:ok` (idempotent)."
  @callback revoke(principal_id :: String.t(), permission :: String.t()) :: :ok

  @doc """
  Check whether `principal_id` has been granted `permission`. Wildcard
  matching (`*`) and segment matching are implementation-defined.
  """
  @callback check(principal_id :: String.t(), permission :: String.t()) :: boolean()
end

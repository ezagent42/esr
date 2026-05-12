defmodule Esr.Uri.Plugin do
  @moduledoc """
  Behaviour every plugin URI handler implements. Plugins declare URI
  subtrees in their manifest (`uri_subtrees:` block) and provide a
  handler module that implements these two callbacks.

  Spec: docs/superpowers/specs/2026-05-12-uri-identity-design.md §6
  """

  @callback resolve(remaining_segments :: [String.t()])
              :: {:ok, canonical_uri :: String.t()} | :not_found | :invalid_format

  @callback alias(canonical_uri :: String.t(), args :: map())
              :: {:ok, alias_uri :: String.t()} | {:error, term()}
end

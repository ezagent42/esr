defmodule Esr.Plugin.Version do
  @moduledoc """
  SemVer constraint check for `depends_on.core`.

  Wraps Elixir stdlib `Version` module. Thin — the only reason for this
  module is to centralize the error handling shape and provide
  `esrd_version/0` in one place.

  Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §6 (D8).
  """

  @doc """
  Check whether `version` satisfies `constraint`.

  Returns `true | false` on success, or `{:error, :invalid_constraint}`
  when either string is not valid SemVer / not a valid constraint.

  Uses Elixir stdlib `Version.match?/2` under the hood.
  """
  @spec satisfies?(constraint :: String.t(), version :: String.t()) ::
          boolean() | {:error, :invalid_constraint}
  def satisfies?(constraint, version) when is_binary(constraint) and is_binary(version) do
    try do
      Version.match?(version, constraint)
    rescue
      _ -> {:error, :invalid_constraint}
    end
  end

  def satisfies?(_constraint, _version), do: {:error, :invalid_constraint}

  @doc """
  Return the running ESR version as a SemVer string.

  Reads from the `:esr` application spec at runtime (populated by
  `mix.exs`'s `@version`). Falls back to `"0.0.0"` if the app spec
  is unavailable (e.g. in unit tests that don't start the application).
  """
  @spec esrd_version() :: String.t()
  def esrd_version do
    case Application.spec(:esr, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end
end

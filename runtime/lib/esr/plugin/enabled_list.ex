defmodule Esr.Plugin.EnabledList do
  @moduledoc """
  Read the enabled-plugins list from `plugins.yaml`.

  Track 0 Task 0.5. Used by `config/runtime.exs` to populate
  `Application.get_env(:esr, :enabled_plugins)` at boot. Extracted
  into a module so we can unit-test the parsing semantics — runtime.exs
  itself is not directly testable.

  ## File schema

      enabled:
        - feishu
        - claude_code

  ## Behavior

  * Missing file → returns the legacy default `["feishu",
    "claude_code"]` so today's runtime keeps booting with the core
    chat + agent plugins enabled. (PR-2.0 dropped voice; PR-3.1
    dropped voice from this list to match.)
  * `enabled: []` (explicit empty list) → returns `[]`. Distinguished
    from "missing file" so operators can opt into core-only.
  * Malformed yaml or missing `enabled:` key → falls back to the
    legacy default. Operators can fix the file and restart.
  """

  @legacy_default ["feishu", "claude_code"]

  @doc """
  Read `path` and return the enabled list, applying the fallback
  policy described in the moduledoc. Pure function.
  """
  @spec read(Path.t()) :: [String.t()]
  def read(path) do
    case File.read(path) do
      {:ok, content} ->
        parse_yaml(content)

      {:error, :enoent} ->
        @legacy_default

      {:error, _other} ->
        @legacy_default
    end
  end

  @doc "The legacy default list (everything-enabled fallback)."
  @spec legacy_default() :: [String.t()]
  def legacy_default, do: @legacy_default

  defp parse_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, %{"enabled" => list}} when is_list(list) ->
        Enum.filter(list, &is_binary/1)

      _ ->
        @legacy_default
    end
  end
end

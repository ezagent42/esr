defmodule Esr.Plugin.EnabledList do
  @moduledoc """
  Read the enabled-plugins list from `plugins.yaml`.

  Per yaml-layout-v2 (spec § 4.2): `plugins.yaml` is enabled-only.
  Any top-level key besides `enabled` (e.g. `config:`) **raises** at
  read time — there is no longer a `:config` block; per-plugin config
  lives at `plugins/<name>/config.yaml`.

  ## File schema

      enabled:
        - feishu
        - claude_code

  ## Behavior

  * Missing file → returns the legacy default `["feishu",
    "claude_code"]` so today's runtime keeps booting with the core
    chat + agent plugins enabled.
  * `enabled: []` (explicit empty list) → returns `[]`. Distinguished
    from "missing file" so operators can opt into core-only.
  * Malformed yaml → falls back to the legacy default. Operators can
    fix the file and restart.
  * Yaml contains a non-`enabled` top-level key (e.g. `config:`) →
    **raises**. Hard cutover; no auto-migration.
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
        parse_yaml(content, path)

      {:error, :enoent} ->
        @legacy_default

      {:error, _other} ->
        @legacy_default
    end
  end

  @doc "The legacy default list (everything-enabled fallback)."
  @spec legacy_default() :: [String.t()]
  def legacy_default, do: @legacy_default

  defp parse_yaml(content, path) do
    case YamlElixir.read_from_string(content) do
      {:ok, parsed} when is_map(parsed) ->
        :ok = check_no_legacy_keys!(parsed, path)

        case parsed do
          %{"enabled" => list} when is_list(list) ->
            Enum.filter(list, &is_binary/1)

          _ ->
            @legacy_default
        end

      _ ->
        @legacy_default
    end
  end

  # Hard-cutover guard: the yaml-layout-v2 design moved per-plugin
  # config out of plugins.yaml. Any leftover `config:` (or other
  # non-enabled key) is operator error — surfacing as a raise lets the
  # operator notice and clean up rather than silently dropping data.
  defp check_no_legacy_keys!(parsed, path) when is_map(parsed) do
    extras = Map.keys(parsed) -- ["enabled"]

    case extras do
      [] ->
        :ok

      _ ->
        raise """
        plugins.yaml at #{path} contains non-enabled top-level keys: #{inspect(extras)}.
        Per yaml-layout-v2 (spec 2026-05-09), plugins.yaml is enabled-only.
        Per-plugin config now lives under plugins/<name>/config.yaml.
        Edit the file to remove the extra keys (commonly `config:`).
        """
    end
  end
end

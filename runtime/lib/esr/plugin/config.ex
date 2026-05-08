defmodule Esr.Plugin.Config do
  @moduledoc """
  3-layer plugin config resolution: global / user / workspace.

  Precedence: workspace > user > global (per-key merge, most-specific wins).
  An explicit empty string `""` at a more-specific layer wins over a
  non-empty value at a less-specific layer (e.g. "disable proxy for this
  workspace").

  ## Layer file locations (production defaults)

    * global:    `$ESRD_HOME/<inst>/plugins.yaml`         (`:enabled` + `:config`)
    * user:      `$ESRD_HOME/<inst>/users/<uuid>/.esr/plugins.yaml`  (`:config` only)
    * workspace: `<workspace_root>/.esr/plugins.yaml`     (`:config` only)

  ## Public API

    * `resolve/2` — merge all layers, return a flat config map.
    * `get/3`     — convenience: resolve + fetch one key.
    * `store_layer/4` — write one key to a specific layer file (atomic).
    * `delete_layer/3` — remove one key from a specific layer file.

  Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §6.
  """

  require Logger

  @doc """
  Resolve effective config for `plugin_name`. All layers are optional;
  pass paths via opts.

  Opts:
    * `:global_path`    — path to global plugins.yaml
    * `:user_path`      — path to user-layer plugins.yaml
    * `:workspace_path` — path to workspace-layer plugins.yaml

  Returns a flat `%{key => value}` map. Missing files are treated as
  empty layers (not errors).
  """
  @spec resolve(plugin_name :: String.t(), opts :: keyword()) :: map()
  def resolve(plugin_name, opts \\ []) do
    global = read_layer(opts[:global_path], plugin_name)
    user = read_layer(opts[:user_path], plugin_name)
    workspace = read_layer(opts[:workspace_path], plugin_name)

    global
    |> merge_layer(user)
    |> merge_layer(workspace)
  end

  @doc """
  Resolve and return a single config key for `plugin_name`, or `nil`
  if absent in all layers.
  """
  @spec get(plugin_name :: String.t(), key :: String.t(), opts :: keyword()) :: term() | nil
  def get(plugin_name, key, opts \\ []) do
    resolve(plugin_name, opts) |> Map.get(key)
  end

  @doc """
  Write a single key-value pair to the specified layer file.

  Opts (required for the target layer):
    * `:layer`          — `:global | :user | :workspace`
    * `:global_path`    — required when `layer: :global`
    * `:user_path`      — required when `layer: :user`
    * `:workspace_path` — required when `layer: :workspace`

  Atomic: reads the file, merges the key, writes to a temp path, then
  renames. Returns `:ok` on success; raises on file-system error.
  """
  @spec store_layer(
          plugin_name :: String.t(),
          key :: String.t(),
          value :: term(),
          opts :: keyword()
        ) :: :ok
  def store_layer(plugin_name, key, value, opts) do
    path = layer_path!(opts)
    update_layer_file(path, plugin_name, fn cfg -> Map.put(cfg, key, value) end)
  end

  @doc """
  Remove a single key from the specified layer file. Idempotent.
  Returns `:ok` even if the key was absent.
  """
  @spec delete_layer(plugin_name :: String.t(), key :: String.t(), opts :: keyword()) :: :ok
  def delete_layer(plugin_name, key, opts) do
    path = layer_path!(opts)
    update_layer_file(path, plugin_name, fn cfg -> Map.delete(cfg, key) end)
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp read_layer(nil, _plugin_name), do: %{}

  defp read_layer(path, plugin_name) do
    case File.read(path) do
      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("plugin_config: cannot read #{path}: #{inspect(reason)}")
        %{}

      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, parsed} ->
            get_in(parsed, ["config", plugin_name]) || %{}

          {:error, reason} ->
            Logger.warning("plugin_config: yaml parse error #{path}: #{inspect(reason)}")
            %{}
        end
    end
  end

  # Layer merge: base keys survive unless explicitly set in overlay.
  # Explicit empty string in overlay wins (e.g. http_proxy: "" disables proxy).
  # Only absent keys (not present in overlay) fall back to base.
  defp merge_layer(base, overlay) when is_map(overlay) do
    Map.merge(base, overlay)
  end

  defp merge_layer(base, _), do: base

  defp layer_path!(opts) do
    case opts[:layer] do
      :global ->
        opts[:global_path] || raise ArgumentError, "global_path required for layer: :global"

      :user ->
        opts[:user_path] || raise ArgumentError, "user_path required for layer: :user"

      :workspace ->
        opts[:workspace_path] ||
          raise ArgumentError, "workspace_path required for layer: :workspace"

      other ->
        raise ArgumentError,
              "unknown layer #{inspect(other)}; must be :global | :user | :workspace"
    end
  end

  defp update_layer_file(path, plugin_name, updater_fn) do
    # Read existing content (may not exist yet).
    existing =
      case File.read(path) do
        {:ok, content} ->
          case YamlElixir.read_from_string(content) do
            {:ok, parsed} when is_map(parsed) -> parsed
            _ -> %{}
          end

        _ ->
          %{}
      end

    # Merge updated plugin config into existing content.
    current_cfg = get_in(existing, ["config", plugin_name]) || %{}
    updated_cfg = updater_fn.(current_cfg)

    # Rebuild the full file map.
    updated_file =
      existing
      |> Map.put("config", Map.put(existing["config"] || %{}, plugin_name, updated_cfg))

    # Serialize and write atomically.
    yaml_content = yaml_encode(updated_file)
    tmp_path = path <> ".tmp.#{:rand.uniform(999_999)}"
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    File.write!(tmp_path, yaml_content)
    File.rename!(tmp_path, path)
    :ok
  end

  # Minimal YAML encoder for plugin config maps.
  # Only handles string/boolean/integer scalar values + string keys.
  defp yaml_encode(map, indent \\ 0) when is_map(map) do
    prefix = String.duplicate("  ", indent)

    map
    |> Enum.map(fn {k, v} ->
      key_str = "#{prefix}#{k}:"

      case v do
        v when is_map(v) ->
          "#{key_str}\n#{yaml_encode(v, indent + 1)}"

        v when is_binary(v) ->
          ~s(#{key_str} "#{String.replace(v, "\"", "\\\"")}")

        v ->
          "#{key_str} #{v}"
      end
    end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end
end

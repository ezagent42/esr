defmodule Esr.Plugin.Config do
  @moduledoc """
  3-layer plugin config resolution: global / user / workspace.

  Precedence: workspace > user > global (per-key merge, most-specific wins).
  An explicit empty string `""` at a more-specific layer wins over a
  non-empty value at a less-specific layer (e.g. "disable proxy for this
  workspace").

  ## Layer directory locations (yaml-layout-v2, spec § 4.1)

    * global:    `$ESRD_HOME/<inst>/plugins/<name>/config.yaml`
    * user:      `$ESRD_HOME/<inst>/users/<uuid>/.esr/plugins/<name>/config.yaml`
    * workspace: `<workspace_root>/.esr/plugins/<name>/config.yaml`

  Each `config.yaml` is a flat map (no `:config` wrapper, no other
  plugins' configs). Empty file / missing file at any layer contributes
  nothing.

  ## Public API (names unchanged from v1; semantics of path opts now
  point at the per-plugin directory, not a monolithic plugins.yaml)

    * `resolve/2`     — merge all layers, return a flat config map.
    * `get/3`         — convenience: resolve + fetch one key.
    * `store_layer/4` — write one key to a specific layer (atomic).
    * `delete_layer/3` — remove one key from a specific layer.

  Spec: docs/superpowers/specs/2026-05-09-yaml-layout-v2-per-thing-directories.md §4.1.

  ## Failure mode

  **Malformed yaml at any layer raises** — broken `config.yaml` is
  operator error worth surfacing immediately, not silently masked.
  """

  @doc """
  Resolve effective config for `plugin_name`. All layers are optional;
  pass per-plugin directory paths via opts.

  Opts:
    * `:global_path`    — path to the per-plugin global directory
                          (`$ESRD_HOME/<inst>/plugins/<name>/`)
    * `:user_path`      — path to the per-plugin user directory
    * `:workspace_path` — path to the per-plugin workspace directory

  Returns a flat `%{key => value}` map. Missing files are treated as
  empty layers (not errors).
  """
  @spec resolve(plugin_name :: String.t(), opts :: keyword()) :: map()
  def resolve(plugin_name, opts \\ []) when is_binary(plugin_name) do
    global = read_layer(opts[:global_path])
    user = read_layer(opts[:user_path])
    workspace = read_layer(opts[:workspace_path])

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
  Write a single key-value pair to the specified layer.

  Opts (required for the target layer):
    * `:layer`          — `:global | :user | :workspace`
    * `:global_path`    — required when `layer: :global` (per-plugin dir)
    * `:user_path`      — required when `layer: :user`     (per-plugin dir)
    * `:workspace_path` — required when `layer: :workspace` (per-plugin dir)

  Atomic: reads the layer's `config.yaml`, merges the key, writes to a
  temp path under the same dir, then renames. Returns `:ok` on success.
  """
  @spec store_layer(
          plugin_name :: String.t(),
          key :: String.t(),
          value :: term(),
          opts :: keyword()
        ) :: :ok
  def store_layer(plugin_name, key, value, opts) when is_binary(plugin_name) do
    dir = layer_dir!(opts)
    update_config_yaml(dir, fn cfg -> Map.put(cfg, key, value) end)
  end

  @doc """
  Remove a single key from the specified layer's `config.yaml`.
  Idempotent. Returns `:ok` even if the key was absent.
  """
  @spec delete_layer(plugin_name :: String.t(), key :: String.t(), opts :: keyword()) :: :ok
  def delete_layer(plugin_name, key, opts) when is_binary(plugin_name) do
    dir = layer_dir!(opts)
    update_config_yaml(dir, fn cfg -> Map.delete(cfg, key) end)
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp read_layer(nil), do: %{}

  defp read_layer(dir) do
    path = Path.join(dir, "config.yaml")

    case File.read(path) do
      # Layer not yet created (dir absent OR config.yaml absent). Either
      # is "no config at this layer" — never an error.
      {:error, reason} when reason in [:enoent, :enotdir] ->
        %{}

      {:error, reason} ->
        raise "plugin_config: cannot read #{path}: #{inspect(reason)}"

      {:ok, ""} ->
        %{}

      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, parsed} when is_map(parsed) ->
            parsed

          {:ok, nil} ->
            %{}

          {:ok, other} ->
            raise "plugin_config: #{path} root must be a map, got #{inspect(other)}"

          {:error, reason} ->
            raise "plugin_config: yaml parse error in #{path}: #{inspect(reason)}"
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

  defp layer_dir!(opts) do
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

  defp update_config_yaml(dir, updater_fn) do
    path = Path.join(dir, "config.yaml")
    current_cfg = read_layer(dir)
    updated_cfg = updater_fn.(current_cfg)
    yaml_content = yaml_encode(updated_cfg)

    File.mkdir_p!(dir)
    tmp_path = path <> ".tmp.#{:rand.uniform(999_999)}"
    File.write!(tmp_path, yaml_content)
    File.rename!(tmp_path, path)
    :ok
  end

  # Minimal YAML encoder for plugin config maps.
  # Only handles string/boolean/integer scalar values + string keys.
  defp yaml_encode(map, indent \\ 0) when is_map(map) do
    if map_size(map) == 0 do
      "{}\n"
    else
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
end

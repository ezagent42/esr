defmodule Esr.Plugin.Manifest do
  @moduledoc """
  Parse + validate a plugin's `manifest.yaml`.

  Spec: `docs/superpowers/specs/2026-05-04-plugin-mechanism-design.md` §四.

  Phase-1 schema (kept lenient on optional declarations — the Loader
  only consumes the keys it knows about; unrecognized declarations are
  retained on the struct as raw map data so future loaders can read
  them without re-parsing).

  ## Validation surface

  `parse/1` enforces: required top-level fields (`name`, `version`),
  kebab-case `name`, depends_on shape with safe defaults.

  `validate/1` enforces: capability-namespace-prefix rule
  (`<plugin>/<rest>`) and module existence for declared entities (via
  `Code.ensure_loaded?/1`). The reason for the split: parse/1 is what
  /plugin info reads (cheap, no module loading); validate/1 runs at
  Loader.start_plugin/2 time before contributions are registered.
  """

  defstruct [
    :name,
    :version,
    :description,
    :depends_on,
    :declares,
    # path to the manifest.yaml (used by Loader to resolve `priv/*.yaml`
    # references back to absolute paths)
    :path,
    # Whether the plugin supports /plugin:reload without esrd restart.
    # Declared in manifest as `hot_reloadable: true|false`. Default: false.
    # Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §3.
    hot_reloadable: false,
    # Top-level `channels:` block (sibling of `name:`/`version:`). Each
    # entry: `%{name: String.t(), module: module(), config_schema: map()
    # | nil}`. Loader registers these into `Esr.Channel.Registry` at
    # boot. Spec: 2026-05-10-session-template-and-channel.md, Phase 1.
    channels: []
  ]

  @type channel_entry :: %{
          name: String.t(),
          module: module(),
          config_schema: map() | nil
        }

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          description: String.t(),
          depends_on: %{core: String.t(), plugins: [String.t()]},
          declares: map(),
          hot_reloadable: boolean(),
          path: Path.t() | nil,
          channels: [channel_entry()]
        }

  # Allow lowercase + digits + `-` or `_` separators. Spec B §四
  # specifies "kebab-case" but the legacy default list inherited from
  # config (`claude_code`) is snake_case; rather than churn the legacy
  # name, we accept either separator. Mixed (`foo-bar_baz`) is fine —
  # the rule is "lowercase token segments separated by - or _".
  @kebab_case ~r/^[a-z][a-z0-9]*([-_][a-z0-9]+)*$/

  @known_media_types ~w(image file audio)a

  @doc """
  Parse `manifest.yaml` at `path`. Returns `{:ok, struct}` or
  `{:error, reason}`.

  Performs schema-shape validation only; does NOT touch module loading
  (use `validate/1` for that).
  """
  @spec parse(Path.t()) :: {:ok, t()} | {:error, term()}
  def parse(path) do
    with {:ok, content} <- read_file(path),
         {:ok, parsed} <- read_yaml(content, path),
         {:ok, manifest} <- parse_raw(parsed) do
      {:ok, %{manifest | path: path}}
    end
  end

  @doc """
  Parse a manifest from a YAML string (in-memory). Returns `{:ok,
  struct}` or `{:error, reason}`. The `:path` field on the returned
  struct will be `nil`.

  Useful for tests and introspection tools that don't have a file on
  disk (e.g. `/plugin info` over a manifest fetched from a remote
  registry).
  """
  @spec parse_string(String.t()) :: {:ok, t()} | {:error, term()}
  def parse_string(content) when is_binary(content) do
    with {:ok, parsed} <- read_yaml(content, "<string>"),
         {:ok, manifest} <- parse_raw(parsed) do
      {:ok, manifest}
    end
  end

  # Shared parse logic for both parse/1 and parse_string/1.
  defp parse_raw(parsed) do
    with {:ok, name} <- fetch_required(parsed, "name"),
         :ok <- validate_kebab(name),
         {:ok, version} <- fetch_required(parsed, "version"),
         {:ok, config_schema} <- parse_config_schema(parsed["config_schema"] || %{}),
         {:ok, hot_reloadable} <- parse_hot_reloadable(parsed),
         {:ok, channels} <- parse_channels(parsed["channels"]) do
      raw_declares = parsed["declares"] || %{}
      declares = atomize_declares(raw_declares)
      raw_media_types = raw_declares["media_types"] || raw_declares[:media_types]

      with {:ok, media_types} <- parse_media_types(raw_media_types) do
        declares_full =
          declares
          |> Map.put(:config_schema, config_schema)
          |> Map.put(:media_types, media_types)

        {:ok,
         %__MODULE__{
           name: name,
           version: version,
           description: parsed["description"] || "",
           depends_on: parse_depends_on(parsed["depends_on"] || %{}),
           declares: declares_full,
           hot_reloadable: hot_reloadable,
           path: nil,
           channels: channels
         }}
      end
    end
  end

  @doc """
  Validate semantic rules: cap-prefix enforcement + module existence.

  Run at `Esr.Plugin.Loader.start_plugin/2` time, after parse, before
  registering contributions.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = manifest) do
    with :ok <- validate_caps(manifest),
         :ok <- validate_entities(manifest),
         :ok <- validate_slash_routes(manifest) do
      :ok
    end
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:read_failed, reason, path}}
    end
  end

  defp read_yaml(content, path) do
    case YamlElixir.read_from_string(content) do
      {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
      {:ok, _other} -> {:error, {:not_a_map, path}}
      {:error, reason} -> {:error, {:parse_failed, reason, path}}
    end
  end

  defp fetch_required(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp validate_kebab(name) do
    if Regex.match?(@kebab_case, name) do
      :ok
    else
      {:error, {:invalid_name, name}}
    end
  end

  defp parse_depends_on(map) when is_map(map) do
    %{
      core: map["core"] || ">= 0.0.0",
      plugins: map["plugins"] || []
    }
  end

  defp parse_depends_on(_), do: %{core: ">= 0.0.0", plugins: []}

  # ---- config_schema parsing (Phase 7.1) ----

  @supported_schema_types ~w(string boolean)

  defp parse_config_schema(schema_map) when is_map(schema_map) do
    Enum.reduce_while(schema_map, {:ok, %{}}, fn {key, entry}, {:ok, acc} ->
      with {:ok, type} <- fetch_schema_field(key, entry, "type"),
           :ok <- validate_schema_type(key, type),
           {:ok, description} <- fetch_schema_field(key, entry, "description"),
           {:ok, default} <- fetch_schema_field_with_nil(key, entry, "default") do
        {:cont,
         {:ok,
          Map.put(acc, key, %{"type" => type, "description" => description, "default" => default})}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_config_schema(_), do: {:ok, %{}}

  defp fetch_schema_field(key, entry, field) when is_map(entry) do
    case Map.fetch(entry, field) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, {:config_schema_missing_field, key, field}}
    end
  end

  defp fetch_schema_field(key, _entry, field),
    do: {:error, {:config_schema_missing_field, key, field}}

  # `default` is allowed to be nil (absent key = missing field error),
  # but an explicit `false` or `""` must be accepted (Map.fetch returns
  # {:ok, false} which the guard `not is_nil(value)` allows).
  # We use Map.has_key? to distinguish "key present with nil value" from
  # "key absent". YAML `default: ` (bare) parses as nil → missing field.
  defp fetch_schema_field_with_nil(key, entry, field) when is_map(entry) do
    if Map.has_key?(entry, field) do
      {:ok, Map.get(entry, field)}
    else
      {:error, {:config_schema_missing_field, key, field}}
    end
  end

  defp fetch_schema_field_with_nil(key, _entry, field),
    do: {:error, {:config_schema_missing_field, key, field}}

  defp validate_schema_type(key, type) when is_binary(type) do
    if type in @supported_schema_types do
      :ok
    else
      {:error, {:config_schema_unknown_type, key, type}}
    end
  end

  defp validate_schema_type(key, type),
    do: {:error, {:config_schema_unknown_type, key, inspect(type)}}

  # Convert the top-level keys of `declares` into atoms for
  # struct-friendly access. Sub-values stay as plain maps (yaml-shape).
  defp atomize_declares(declares) when is_map(declares) do
    for {key, value} <- declares, into: %{} do
      {String.to_atom(key), value}
    end
  end

  defp atomize_declares(_), do: %{}

  # ---- media_types parser (D5) ----

  defp parse_media_types(nil), do: {:ok, %{inbound: [], outbound: []}}

  defp parse_media_types(%{} = block) do
    with {:ok, inbound} <-
           parse_media_list(Map.get(block, "inbound") || Map.get(block, :inbound) || []),
         {:ok, outbound} <-
           parse_media_list(Map.get(block, "outbound") || Map.get(block, :outbound) || []) do
      {:ok, %{inbound: inbound, outbound: outbound}}
    end
  end

  defp parse_media_types(_), do: {:error, "media_types must be a map"}

  defp parse_media_list(list) when is_list(list) do
    result =
      Enum.reduce_while(list, {:ok, []}, fn s, {:ok, acc} ->
        atom = String.to_atom(to_string(s))

        if atom in @known_media_types do
          {:cont, {:ok, [atom | acc]}}
        else
          {:halt, {:error, "unknown media_type: #{s}"}}
        end
      end)

    case result do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end

  defp parse_media_list(_), do: {:error, "media_types list must be a list"}

  # ---- hot_reloadable parser (HR-1) ----

  defp parse_hot_reloadable(parsed) do
    case parsed["hot_reloadable"] do
      nil   -> {:ok, false}
      true  -> {:ok, true}
      false -> {:ok, false}
      other -> {:error, {:invalid_hot_reloadable, other}}
    end
  end

  # ---- channels parser (2026-05-10 SessionTemplate + Channel migration, Phase 1) ----
  #
  # Top-level `channels:` block. Each entry must be a map carrying
  # string `name` + string `module`; an optional `config_schema:` map
  # is preserved as-is. The module string is resolved with
  # `Code.ensure_loaded?/1`; an unknown module aborts parse with
  # `{:invalid_channel, {:unknown_module, name, module_str}}`.
  #
  # Validation lives here (not in validate/1) for symmetry with
  # config_schema and media_types — the manifest's at-rest shape is
  # established at parse time so /plugin info doesn't see a half-validated
  # struct.
  defp parse_channels(nil), do: {:ok, []}

  defp parse_channels(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case parse_channel_entry(entry) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_channel, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end

  defp parse_channels(other), do: {:error, {:invalid_channel, {:not_a_list, other}}}

  defp parse_channel_entry(%{} = entry) do
    name = entry["name"] || entry[:name]
    module_str = entry["module"] || entry[:module]
    config_schema = entry["config_schema"] || entry[:config_schema]

    cond do
      not is_binary(name) or name == "" ->
        {:error, {:missing_field, "name"}}

      not is_binary(module_str) or module_str == "" ->
        {:error, {:missing_field, "module"}}

      true ->
        module = Module.concat([module_str])

        if Code.ensure_loaded?(module) do
          {:ok, %{name: name, module: module, config_schema: config_schema}}
        else
          {:error, {:unknown_module, name, module_str}}
        end
    end
  end

  defp parse_channel_entry(other), do: {:error, {:not_a_map, other}}

  # ---- validate/1 helpers ----

  defp validate_caps(%__MODULE__{name: name, declares: declares}) do
    caps = Map.get(declares, :capabilities, [])

    Enum.reduce_while(caps, :ok, fn cap, :ok ->
      case String.split(cap, "/", parts: 2) do
        [prefix, _rest] when prefix == name ->
          {:cont, :ok}

        [_prefix, _rest] ->
          {:halt, {:error, {:bad_cap_prefix, cap, name}}}

        _ ->
          {:halt, {:error, {:bad_cap_shape, cap}}}
      end
    end)
  end

  defp validate_entities(%__MODULE__{declares: declares}) do
    entities = Map.get(declares, :entities, [])

    Enum.reduce_while(entities, :ok, fn entity, :ok ->
      module_str = entity_module_name(entity)
      module = Module.concat([module_str])

      if Code.ensure_loaded?(module) do
        {:cont, :ok}
      else
        {:halt, {:error, {:unknown_module, module_str}}}
      end
    end)
  end

  defp entity_module_name(%{"module" => name}), do: name
  defp entity_module_name(%{module: name}), do: name
  defp entity_module_name(other), do: inspect(other)

  # slash_routes validator (audit #6 / 2026-05-08-plugin-command-registration spec).
  #
  # Hard constraints enforced here (manifest validate time):
  #   - every slash key must match `^/<plugin_name>:`
  #   - every kind must start with `<plugin_name>_`
  #   - every permission must be in this manifest's own capabilities list
  #   - every command_module must be loadable AND start with
  #     `Esr.Plugins.<PluginCamel>.`
  #
  # Belt-and-suspenders: SlashRoute.Registry.register_overlay/2 re-checks
  # at register time (catches manifests hand-edited at runtime).
  defp validate_slash_routes(%__MODULE__{name: name, declares: declares}) do
    case Map.get(declares, :slash_routes) do
      nil ->
        :ok

      block when is_map(block) ->
        caps = Map.get(declares, :capabilities, [])
        slashes = Map.get(block, "slashes", %{}) || %{}
        kinds = Map.get(block, "internal_kinds", %{}) || %{}

        with :ok <- validate_slash_keys(slashes, name),
             :ok <- validate_kind_names(slashes, kinds, name),
             :ok <- validate_permission_subset(slashes, kinds, caps),
             :ok <- validate_command_modules(slashes, kinds, name) do
          :ok
        end

      other ->
        {:error, {:invalid_slash_routes_block, name, other}}
    end
  end

  defp validate_slash_keys(slashes, plugin_name) do
    prefix = "/" <> plugin_name <> ":"

    Enum.reduce_while(Map.keys(slashes), :ok, fn key, :ok ->
      if String.starts_with?(key, prefix) do
        {:cont, :ok}
      else
        {:halt, {:error, {:bad_slash_prefix, key, plugin_name}}}
      end
    end)
  end

  defp validate_kind_names(slashes, kinds, plugin_name) do
    prefix = plugin_name <> "_"

    slash_kinds =
      slashes
      |> Map.values()
      |> Enum.flat_map(fn entry ->
        case Map.get(entry, "kind") do
          k when is_binary(k) -> [k]
          _ -> []
        end
      end)

    all_kinds = slash_kinds ++ Map.keys(kinds)

    Enum.reduce_while(all_kinds, :ok, fn kind, :ok ->
      if String.starts_with?(kind, prefix) do
        {:cont, :ok}
      else
        {:halt, {:error, {:bad_kind_prefix, kind, plugin_name}}}
      end
    end)
  end

  defp validate_permission_subset(slashes, kinds, caps) do
    declared = MapSet.new(caps)

    refs =
      (Map.values(slashes) ++ Map.values(kinds))
      |> Enum.flat_map(fn entry ->
        case Map.get(entry, "permission") do
          nil -> []
          "" -> []
          p when is_binary(p) -> [p]
        end
      end)

    Enum.reduce_while(refs, :ok, fn perm, :ok ->
      if MapSet.member?(declared, perm) do
        {:cont, :ok}
      else
        {:halt, {:error, {:cross_plugin_permission, perm}}}
      end
    end)
  end

  defp validate_command_modules(slashes, kinds, plugin_name) do
    prefix = "Elixir.Esr.Plugins." <> Macro.camelize(plugin_name) <> "."

    refs =
      (Map.values(slashes) ++ Map.values(kinds))
      |> Enum.flat_map(fn entry ->
        case Map.get(entry, "command_module") do
          m when is_binary(m) -> [m]
          _ -> []
        end
      end)

    Enum.reduce_while(refs, :ok, fn mod_str, :ok ->
      fully_qualified =
        if String.starts_with?(mod_str, "Elixir."),
          do: mod_str,
          else: "Elixir." <> mod_str

      cond do
        not String.starts_with?(fully_qualified, prefix) ->
          {:halt, {:error, {:bad_command_module_prefix, mod_str, plugin_name}}}

        true ->
          mod = String.to_atom(fully_qualified)

          if Code.ensure_loaded?(mod) do
            {:cont, :ok}
          else
            {:halt, {:error, {:unknown_command_module, mod_str}}}
          end
      end
    end)
  end

  # PR-3.4 (2026-05-05): startup-hook validation. Required fields:
  # `module:` and `function:`. No defaults — missing field triggers an
  # explicit error so the operator sees the typo at boot rather than a
  # silent no-op.
  @doc """
  Read + validate the `startup:` block of `manifest`. Returns
  `{:ok, {module, function_atom}}` for the configured startup callback,
  `:none` when no `startup:` block is declared, or `{:error, reason}`
  on a malformed block.

  Used by `Esr.Plugin.Loader.register_startup/1`.
  """
  @spec startup_callback(t()) ::
          {:ok, {module(), atom()}} | :none | {:error, term()}
  def startup_callback(%__MODULE__{name: plugin_name, declares: declares}) do
    case Map.get(declares, :startup) do
      nil ->
        :none

      block when is_map(block) ->
        with {:ok, module_str} <- fetch_startup_field(block, "module", plugin_name),
             {:ok, function_str} <- fetch_startup_field(block, "function", plugin_name),
             {:ok, module} <- resolve_module(module_str, plugin_name),
             function_atom <- String.to_atom(function_str),
             :ok <- ensure_exported(module, function_atom, plugin_name) do
          {:ok, {module, function_atom}}
        end

      other ->
        {:error, {:invalid_startup_block, plugin_name, other}}
    end
  end

  defp fetch_startup_field(block, key, plugin_name) do
    case Map.get(block, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:startup_field_missing, plugin_name, key}}
    end
  end

  defp resolve_module(module_str, plugin_name) do
    module = Module.concat([module_str])

    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      {:error, {:startup_module_not_loadable, plugin_name, module_str}}
    end
  end

  defp ensure_exported(module, function_atom, plugin_name) do
    if function_exported?(module, function_atom, 0) do
      :ok
    else
      {:error, {:startup_function_not_exported, plugin_name, module, function_atom}}
    end
  end
end

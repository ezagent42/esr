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
    :path
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          description: String.t(),
          depends_on: %{core: String.t(), plugins: [String.t()]},
          declares: map(),
          path: Path.t() | nil
        }

  @kebab_case ~r/^[a-z][a-z0-9]*(-[a-z0-9]+)*$/

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
         {:ok, name} <- fetch_required(parsed, "name"),
         :ok <- validate_kebab(name),
         {:ok, version} <- fetch_required(parsed, "version") do
      depends_on = parse_depends_on(parsed["depends_on"] || %{})
      declares = atomize_declares(parsed["declares"] || %{})

      {:ok,
       %__MODULE__{
         name: name,
         version: version,
         description: parsed["description"] || "",
         depends_on: depends_on,
         declares: declares,
         path: path
       }}
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
         :ok <- validate_entities(manifest) do
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

  # Convert the top-level keys of `declares` into atoms for
  # struct-friendly access. Sub-values stay as plain maps (yaml-shape).
  defp atomize_declares(declares) when is_map(declares) do
    for {key, value} <- declares, into: %{} do
      {String.to_atom(key), value}
    end
  end

  defp atomize_declares(_), do: %{}

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
end

defmodule Esr.Bundle.Manifest do
  @moduledoc """
  Parse + validate a bundle's `manifest.yaml`.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md` §5.3.

  A bundle is a first-class single-template artifact. Each bundle dir
  contains exactly two files:

      runtime/lib/esr/bundles/<name>/
        manifest.yaml      # this struct's input
        template.yaml      # parsed by Esr.SessionTemplate.Parser

  The split is deliberate: dependency resolution (this manifest) and
  template rendering (template.yaml) are separate concerns; the loader
  reads `manifest.yaml` first to decide whether to even attempt
  parsing `template.yaml`.

  ## Schema

      schema_version: 1
      name: feishu-cc
      version: 0.1.0
      description: Feishu chat → Claude Code agent (workspace-bound by default)
      dependencies:
        plugins: [feishu, claude_code]    # required, list of plugin names
        bundles: []                       # optional, defaults to []

  ## Loud-fail rules

  Loud failures (parse returns `{:error, reason}`):
    - `schema_version` missing or not equal to `1`
    - `name` missing / empty / non-string
    - `version` missing / empty / non-string
    - `dependencies` missing entirely
    - `dependencies.plugins` missing or not a list
    - any plugin name in `plugins` is non-string / empty
    - any bundle name in `bundles` (when present) is non-string / empty
    - YAML parse fails (malformed yaml)

  History: 2026-05-10 spec, Phase 4 (Task 4.1).
  """

  defstruct [
    :schema_version,
    :name,
    :version,
    :description,
    :dependencies,
    # Path the manifest was read from; nil for `parse_string/1`.
    :path
  ]

  @type dependencies :: %{plugins: [String.t()], bundles: [String.t()]}

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          name: String.t(),
          version: String.t(),
          description: String.t(),
          dependencies: dependencies(),
          path: Path.t() | nil
        }

  @supported_schema_version 1

  @doc """
  Parse `manifest.yaml` at `path`. Returns `{:ok, struct}` or
  `{:error, reason}`.
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
  Parse from a YAML string (in-memory). Path on the struct will be `nil`.
  """
  @spec parse_string(String.t()) :: {:ok, t()} | {:error, term()}
  def parse_string(content) when is_binary(content) do
    with {:ok, parsed} <- read_yaml(content, "<string>"),
         {:ok, manifest} <- parse_raw(parsed) do
      {:ok, manifest}
    end
  end

  defp parse_raw(parsed) do
    with {:ok, schema_version} <- fetch_schema_version(parsed),
         {:ok, name} <- fetch_required_string(parsed, "name"),
         {:ok, version} <- fetch_required_string(parsed, "version"),
         {:ok, dependencies} <- parse_dependencies(parsed["dependencies"]) do
      {:ok,
       %__MODULE__{
         schema_version: schema_version,
         name: name,
         version: version,
         description: parsed["description"] || "",
         dependencies: dependencies,
         path: nil
       }}
    end
  end

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

  defp fetch_schema_version(parsed) do
    case Map.fetch(parsed, "schema_version") do
      {:ok, v} when v == @supported_schema_version ->
        {:ok, v}

      {:ok, other} ->
        {:error, {:schema_version_mismatch, expected: @supported_schema_version, got: other}}

      :error ->
        {:error, {:missing_field, "schema_version"}}
    end
  end

  defp fetch_required_string(parsed, key) do
    case Map.fetch(parsed, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp parse_dependencies(nil), do: {:error, {:missing_field, "dependencies"}}

  defp parse_dependencies(%{} = block) do
    with {:ok, plugins} <- parse_string_list(block, "plugins", required: true),
         {:ok, bundles} <- parse_string_list(block, "bundles", required: false) do
      {:ok, %{plugins: plugins, bundles: bundles}}
    end
  end

  defp parse_dependencies(other), do: {:error, {:invalid_dependencies, other}}

  defp parse_string_list(block, key, opts) do
    required = Keyword.get(opts, :required, false)

    case Map.fetch(block, key) do
      {:ok, list} when is_list(list) ->
        validate_each_string(list, key)

      {:ok, other} ->
        {:error, {:invalid_dependency_list, key, other}}

      :error ->
        if required do
          {:error, {:missing_field, "dependencies." <> key}}
        else
          {:ok, []}
        end
    end
  end

  defp validate_each_string(list, key) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      cond do
        is_binary(entry) and entry != "" -> {:cont, {:ok, [entry | acc]}}
        true -> {:halt, {:error, {:invalid_dependency_entry, key, entry}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end
end

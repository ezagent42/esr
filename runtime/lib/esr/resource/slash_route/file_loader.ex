defmodule Esr.Resource.SlashRoute.Registry.FileLoader do
  @moduledoc """
  Yaml parser + validator for `slash-routes.yaml` (PR-21κ).

  See `docs/notes/yaml-authoring-lessons.md` for the canonical
  4-piece subsystem pattern this follows. Same shape as
  `Esr.Resource.Capability.FileLoader` and `Esr.Resource.Workspace.Registry.load_from_file/1`.
  """

  @behaviour Esr.Role.Control

  require Logger

  alias Esr.Resource.SlashRoute.Registry, as: SlashRouteRegistry

  @doc """
  Load the yaml at `path`, validate, and atomically swap into the
  ETS-backed snapshot. Missing file = empty snapshot, no error.
  Malformed yaml = `:error`, previous snapshot retained.
  """
  @spec load(Path.t()) :: :ok | {:error, term()}
  def load(path) do
    cond do
      not File.exists?(path) ->
        SlashRouteRegistry.load_snapshot(%{slashes: [], internal_kinds: []})
        :ok

      true ->
        with {:ok, yaml} <- parse(path),
             {:ok, snapshot} <- validate(yaml) do
          SlashRouteRegistry.load_snapshot(snapshot)

          slash_count = length(snapshot.slashes)
          kind_count = length(snapshot.internal_kinds)

          Logger.info(
            "slash_routes: loaded #{slash_count} slashes + " <>
              "#{kind_count} internal kinds from #{path}"
          )

          :ok
        else
          {:error, reason} = err ->
            Logger.error(
              "slash_routes: load failed (#{inspect(reason)}); keeping previous snapshot"
            )

            err
        end
    end
  end

  # ------------------------------------------------------------------
  # Parse
  # ------------------------------------------------------------------

  defp parse(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, yaml} -> {:ok, yaml}
      {:error, err} -> {:error, {:yaml_parse, err}}
    end
  end

  # ------------------------------------------------------------------
  # Validate
  # ------------------------------------------------------------------

  defp validate(yaml) when is_map(yaml) do
    with :ok <- validate_schema_version(yaml),
         {:ok, slashes} <- validate_slashes(Map.get(yaml, "slashes", %{})),
         {:ok, internal} <- validate_internal_kinds(Map.get(yaml, "internal_kinds", %{})) do
      {:ok, %{slashes: slashes, internal_kinds: internal}}
    end
  end

  defp validate(_), do: {:error, :malformed_root}

  defp validate_schema_version(%{"schema_version" => 1}), do: :ok
  defp validate_schema_version(%{"schema_version" => v}), do: {:error, {:unknown_schema_version, v}}
  defp validate_schema_version(_), do: {:error, :missing_schema_version}

  # ------------------------------------------------------------------
  # Validate slashes:
  # ------------------------------------------------------------------

  defp validate_slashes(%{} = slashes_map) do
    slashes_map
    |> Enum.reduce_while({:ok, []}, fn {key, entry}, {:ok, acc} ->
      case validate_slash_entry(key, entry) do
        {:ok, route} -> {:cont, {:ok, [route | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp validate_slashes(_), do: {:error, :slashes_not_a_map}

  defp validate_slash_entry(key, %{"kind" => kind, "command_module" => mod_str} = entry)
       when is_binary(key) and is_binary(kind) and is_binary(mod_str) do
    with :ok <- validate_slash_key(key),
         {:ok, mod} <- validate_command_module(mod_str),
         {:ok, args} <- validate_args(Map.get(entry, "args", [])) do
      route = %{
        slash: key,
        kind: kind,
        permission: Map.get(entry, "permission"),
        command_module: mod,
        requires_workspace_binding: Map.get(entry, "requires_workspace_binding", false),
        requires_user_binding: Map.get(entry, "requires_user_binding", false),
        category: Map.get(entry, "category"),
        description: Map.get(entry, "description", ""),
        aliases: Map.get(entry, "aliases", []),
        args: args
      }

      {:ok, route}
    end
  end

  defp validate_slash_entry(key, _),
    do: {:error, {:malformed_slash_entry, key}}

  defp validate_slash_key("/" <> _), do: :ok
  defp validate_slash_key(key), do: {:error, {:slash_key_must_start_with_slash, key}}

  # ------------------------------------------------------------------
  # Validate internal_kinds:
  # ------------------------------------------------------------------

  defp validate_internal_kinds(%{} = kinds_map) do
    kinds_map
    |> Enum.reduce_while({:ok, []}, fn {kind, entry}, {:ok, acc} ->
      case validate_internal_kind(kind, entry) do
        {:ok, route} -> {:cont, {:ok, [route | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp validate_internal_kinds(_), do: {:error, :internal_kinds_not_a_map}

  defp validate_internal_kind(kind, %{"command_module" => mod_str} = entry)
       when is_binary(kind) and is_binary(mod_str) do
    with {:ok, mod} <- validate_command_module(mod_str) do
      route = %{
        kind: kind,
        permission: Map.get(entry, "permission"),
        command_module: mod
      }

      {:ok, route}
    end
  end

  defp validate_internal_kind(kind, _),
    do: {:error, {:malformed_internal_kind, kind}}

  # ------------------------------------------------------------------
  # Validate command_module string → atom
  # ------------------------------------------------------------------

  # PR-21κ trap: `Module.safe_concat/1` only resolves modules already
  # in the BEAM atom table; fragile for tests with lazy code-loading +
  # first-boot validation. Use `Code.ensure_loaded?/1` which triggers
  # loading if needed. See docs/notes/yaml-authoring-lessons.md.
  defp validate_command_module(str) when is_binary(str) do
    mod = Module.concat([str])

    if Code.ensure_loaded?(mod) do
      {:ok, mod}
    else
      {:error, {:unknown_module, str}}
    end
  end

  # ------------------------------------------------------------------
  # Validate args list
  # ------------------------------------------------------------------

  defp validate_args([]), do: {:ok, []}
  defp validate_args(args) when is_list(args), do: validate_args_list(args, [])
  defp validate_args(_), do: {:error, :args_not_a_list}

  defp validate_args_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp validate_args_list([%{"name" => name} = arg | rest], acc) when is_binary(name) do
    spec = %{
      name: name,
      required: Map.get(arg, "required", false),
      default: Map.get(arg, "default")
    }

    validate_args_list(rest, [spec | acc])
  end

  defp validate_args_list([bad | _], _),
    do: {:error, {:malformed_arg, bad}}
end

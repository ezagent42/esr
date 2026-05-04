defmodule Esr.Yaml.FragmentMerger do
  @moduledoc """
  Compose a single yaml-domain map from N plugin fragments + a user
  override file. The merged map is what the per-domain Registry's
  `load_snapshot/1` consumes.

  See `docs/superpowers/specs/2026-05-04-core-decoupling-design.md` §三.

  ## Semantics

  Today only **keyed-map** style yaml is supported (the agents.yaml /
  slash-routes.yaml / capabilities.yaml shape: a top-level dictionary
  whose keys are the entity names). Each fragment file looks like:

      <top_key>:
        <name1>:
          <field>: ...
        <name2>:
          ...

  Merge rules per spec §3.2:

    * Plugin fragments contribute new keys; collision on a key across
      two fragments is a hard fail (`{:error, {:duplicate_key, ...}}`).
    * User override file is layered last and may override per-key or
      add brand-new keys.
    * Missing fragment file is silently skipped (plugin may ship an
      empty fragment by omitting the file).
    * Missing user override file is silently skipped (the common case).

  Adapters.yaml (list of instances keyed by `instance_id`) and other
  shapes will be added when their FileLoaders need them; see
  `merge_keyed/2` for the keyed-map case which covers agents,
  slash-routes, and capability declarations.

  ## Wiring status

  Phase 0 ships this module as a pure function with full test coverage.
  The actual rewiring of `Esr.Entity.{Agent,User}.Registry` and
  `Esr.Resource.{SlashRoute,Capability}.FileLoader` to call this merger
  with `Application.get_env(:esr, :enabled_plugins)`-derived fragment
  paths is **deferred to Track 0 Task 0.4** (plugin Loader skeleton),
  because the fragment-path convention
  (`runtime/lib/esr/plugins/<name>/priv/<domain>.yaml`) is enforced by
  the manifest parser landing in that task.
  """

  @typedoc "A `{path, top_level_key}` pair pointing at one yaml fragment."
  @type fragment_ref :: {Path.t(), String.t()}

  @typedoc "Reason a merge can fail."
  @type error ::
          {:duplicate_key, key :: String.t(), first_path :: Path.t(),
           second_path :: Path.t()}
          | {:parse_failed, Path.t(), term()}
          | {:not_a_map, Path.t(), String.t()}

  @doc """
  Merge `fragments` (plugin contributions) plus an optional
  `user_override` into a single map.

  Returns `{:ok, merged_map}` on success or `{:error, reason}` on
  collision / parse failure.

  Pure function: no process state, no side effects beyond File.read/1.
  """
  @spec merge_keyed([fragment_ref()], fragment_ref() | nil) ::
          {:ok, map()} | {:error, error()}
  def merge_keyed(fragments, user_override) when is_list(fragments) do
    with {:ok, base} <- merge_fragments(fragments, %{}, %{}) do
      apply_override(base, user_override)
    end
  end

  # Internal: fold over fragment refs, accumulating both the merged map
  # (`acc`) and a per-key origin index (`origins`) so we can point at
  # the colliding pair if a duplicate appears.
  defp merge_fragments([], acc, _origins), do: {:ok, acc}

  defp merge_fragments([{path, top_key} | rest], acc, origins) do
    case load_keyed(path, top_key) do
      {:ok, contributions} ->
        case absorb(contributions, acc, origins, path) do
          {:ok, acc2, origins2} -> merge_fragments(rest, acc2, origins2)
          {:error, _} = err -> err
        end

      :skip ->
        merge_fragments(rest, acc, origins)

      {:error, _} = err ->
        err
    end
  end

  # Read one yaml file and pull out its top-level keyed map.
  # Returns `:skip` when the file is absent — fragments are optional.
  defp load_keyed(path, top_key) do
    case File.read(path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, parsed} ->
            extract_keyed(parsed, top_key, path)

          {:error, reason} ->
            {:error, {:parse_failed, path, reason}}
        end

      {:error, :enoent} ->
        :skip

      {:error, reason} ->
        {:error, {:parse_failed, path, reason}}
    end
  end

  defp extract_keyed(parsed, top_key, path) when is_map(parsed) do
    case Map.get(parsed, top_key) do
      nil -> {:ok, %{}}
      value when is_map(value) -> {:ok, value}
      _other -> {:error, {:not_a_map, path, top_key}}
    end
  end

  defp extract_keyed(_, _top_key, path), do: {:error, {:not_a_map, path, "<root>"}}

  defp absorb(contributions, acc, origins, path) do
    Enum.reduce_while(contributions, {:ok, acc, origins}, fn {key, value},
                                                              {:ok, acc_map, origins_map} ->
      case Map.fetch(origins_map, key) do
        {:ok, prior_path} ->
          {:halt, {:error, {:duplicate_key, key, prior_path, path}}}

        :error ->
          {:cont,
           {:ok, Map.put(acc_map, key, value), Map.put(origins_map, key, path)}}
      end
    end)
  end

  # User override is applied last with last-write-wins semantics.
  # Missing override file is fine; absent top key is fine.
  defp apply_override(base, nil), do: {:ok, base}

  defp apply_override(base, {path, top_key}) do
    case load_keyed(path, top_key) do
      {:ok, override_map} -> {:ok, Map.merge(base, override_map)}
      :skip -> {:ok, base}
      {:error, _} = err -> err
    end
  end
end

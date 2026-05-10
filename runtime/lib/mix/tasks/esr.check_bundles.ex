defmodule Mix.Tasks.Esr.CheckBundles do
  @moduledoc """
  CI gate: verify every in-tree bundle's manifest + template references
  resolve against the in-tree plugin manifests.

  Phase 8 Task 8.3 of the SessionTemplate + Channel migration (spec
  `docs/superpowers/specs/2026-05-10-session-template-and-channel.md` §10
  acceptance "CI gate: a template referencing a missing channel kind
  fails CI.").

  ## Usage

      mix esr.check_bundles

  Exits 0 (`✅ all bundles ok`) when every bundle's:

    * `manifest.yaml` parses (`Esr.Bundle.Manifest.parse/1`)
    * Every `manifest.dependencies.plugins[]` entry refers to an in-tree
      plugin (under `runtime/lib/esr/plugins/<name>/manifest.yaml`)
    * `template.yaml` parses (`Esr.SessionTemplate.Parser.parse/2`)
    * Every `template.channels[].kind` (`<plugin>.<channel_name>`)
      references a real channel declared in some plugin's `manifest.yaml`
      `channels:` block
    * Every `template.agents[].kind` (`<plugin>.<agent_kind_name>`)
      references a real entry in some plugin's `agent_kinds:` block

  Exits 1 with a structured `{bundle, error_kind, detail}` line per
  failure on the first error class encountered.

  ## Why static parse, not Registry walk

  Same rationale as `mix esr.gen_bundle_docs` — runs against a clean
  checkout (CI; no esrd booted). Walks `runtime/lib/esr/bundles/*/` +
  `runtime/lib/esr/plugins/*/` directly via the manifest parsers. Does
  NOT need the OTP supervision tree booted; this is a static-analysis
  CI gate.

  ## Operator-shipped bundles

  Optionally checks bundle dirs at `~/.esrd-<inst>/<inst>/bundles/*/`
  (post-`/plugin:install` external-bundle copies live there in some
  deployments). Skipped gracefully if the dir is absent — CI runs in a
  clean checkout where it always is.
  """

  use Mix.Task

  @shortdoc "CI gate: verify in-tree bundles' template references resolve to plugin manifests"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")
    Application.load(:esr)

    case check() do
      :ok ->
        Mix.shell().info("✅ all in-tree bundles parse + reference real plugin entries")
        :ok

      {:error, errors} when is_list(errors) and errors != [] ->
        Enum.each(errors, fn {bundle, error_kind, detail} ->
          Mix.shell().error("❌ bundle=#{bundle} kind=#{error_kind} detail=#{inspect(detail)}")
        end)

        Mix.shell().error("regenerate or fix bundle manifest/template, then re-run")
        System.halt(1)
    end
  end

  @doc """
  Pure check — returns `:ok` or `{:error, [{bundle, error_kind, detail}, ...]}`.

  Used by `run/1` and by tests so the failure path is asserted without
  invoking `System.halt/1`. Errors:

    * `:manifest_parse_failed`
    * `:dep_plugin_unknown` — manifest dependency references a plugin
      that doesn't have a manifest.yaml under runtime/lib/esr/plugins/
    * `:template_parse_failed`
    * `:unknown_channel_kind` — template references `<plugin>.<channel>`
      not declared in any plugin's manifest.yaml `channels:` block
    * `:unknown_agent_kind` — template references `<plugin>.<kind>`
      not declared in any plugin's manifest.yaml `agent_kinds:` block
  """
  @spec check(keyword()) :: :ok | {:error, [{String.t(), atom(), term()}]}
  def check(opts \\ []) do
    bundles_root =
      Keyword.get(opts, :bundles_root, default_bundles_root())

    plugins_root =
      Keyword.get(opts, :plugins_root, default_plugins_root())

    # Optional: operator-shipped bundle dirs at ~/.esrd-<inst>/<inst>/bundles/.
    # Off by default in CI; opts can pass `extra_roots: [path, ...]` to
    # include them.
    extra_roots = Keyword.get(opts, :extra_roots, [])

    plugin_index = build_plugin_index(plugins_root)

    bundle_dirs =
      [bundles_root | extra_roots]
      |> Enum.flat_map(&list_bundle_dirs/1)

    errors =
      bundle_dirs
      |> Enum.flat_map(&check_one_bundle(&1, plugin_index))

    case errors do
      [] -> :ok
      list -> {:error, list}
    end
  end

  # ------------------------------------------------------------------
  # Bundle checks
  # ------------------------------------------------------------------

  # Returns a list of {bundle_name, error_kind, detail} for one dir.
  # On manifest parse failure, returns just the manifest error (subsequent
  # checks would cascade). On dep mismatch, continues to template check
  # (operators may have a manifest issue + a template issue independently).
  defp check_one_bundle(dir, plugin_index) do
    bundle_label = Path.basename(dir)
    manifest_path = Path.join(dir, "manifest.yaml")
    template_path = Path.join(dir, "template.yaml")

    case Esr.Bundle.Manifest.parse(manifest_path) do
      {:error, reason} ->
        [{bundle_label, :manifest_parse_failed, reason}]

      {:ok, manifest} ->
        bundle_name = manifest.name

        dep_errors =
          manifest.dependencies.plugins
          |> Enum.reject(&Map.has_key?(plugin_index, &1))
          |> Enum.map(fn missing ->
            {bundle_name, :dep_plugin_unknown, missing}
          end)

        template_errors = check_template(template_path, manifest, plugin_index)

        dep_errors ++ template_errors
    end
  end

  defp check_template(template_path, manifest, plugin_index) do
    case File.read(template_path) do
      {:error, reason} ->
        [{manifest.name, :template_parse_failed, {:read_failed, reason}}]

      {:ok, content} ->
        case Esr.SessionTemplate.Parser.parse(content,
               dependencies: manifest.dependencies,
               verify_channels: false,
               verify_flow_nodes: false
             ) do
          {:error, reason} ->
            [{manifest.name, :template_parse_failed, reason}]

          {:ok, template} ->
            channel_errors =
              template.channels
              |> Enum.reject(&channel_kind_known?(&1.kind, plugin_index))
              |> Enum.map(&{manifest.name, :unknown_channel_kind, &1.kind})

            agent_errors =
              template.agents
              |> Enum.reject(&agent_kind_known?(&1.kind, plugin_index))
              |> Enum.map(&{manifest.name, :unknown_agent_kind, &1.kind})

            channel_errors ++ agent_errors
        end
    end
  end

  defp channel_kind_known?(kind, plugin_index) when is_binary(kind) do
    case String.split(kind, ".", parts: 2) do
      [plugin, channel_name] ->
        case Map.fetch(plugin_index, plugin) do
          {:ok, %{channels: channels}} -> channel_name in channels
          :error -> false
        end

      _ ->
        false
    end
  end

  defp agent_kind_known?(kind, plugin_index) when is_binary(kind) do
    case String.split(kind, ".", parts: 2) do
      [plugin, kind_name] ->
        case Map.fetch(plugin_index, plugin) do
          {:ok, %{agent_kinds: kinds}} -> kind_name in kinds
          :error -> false
        end

      _ ->
        false
    end
  end

  # ------------------------------------------------------------------
  # Plugin index — read every plugin manifest's name + channels +
  # agent_kinds from disk.
  # ------------------------------------------------------------------

  # Returns %{<plugin_name> => %{channels: [String.t()], agent_kinds: [String.t()]}}.
  defp build_plugin_index(plugins_root) do
    case File.ls(plugins_root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(plugins_root, &1)))
        |> Enum.reduce(%{}, fn entry, acc ->
          path = Path.join([plugins_root, entry, "manifest.yaml"])

          case parse_plugin_manifest(path) do
            {:ok, plugin_name, channel_names, agent_kind_names} ->
              Map.put(acc, plugin_name, %{
                channels: channel_names,
                agent_kinds: agent_kind_names
              })

            :error ->
              acc
          end
        end)

      {:error, _} ->
        %{}
    end
  end

  # Parses a plugin manifest YAML directly to extract name + channels[] +
  # agent_kinds[]. Doesn't go through Esr.Plugin.Manifest.parse/1 because
  # that requires module-existence (`Code.ensure_loaded?/1`) which is too
  # strict for this static gate (a plugin's modules may not yet have been
  # picked up by the compile phase if a fresh build is in progress).
  defp parse_plugin_manifest(path) do
    with true <- File.regular?(path),
         {:ok, content} <- File.read(path),
         {:ok, parsed} when is_map(parsed) <- YamlElixir.read_from_string(content),
         name when is_binary(name) and name != "" <- parsed["name"] do
      channel_names =
        case parsed["channels"] do
          list when is_list(list) ->
            list
            |> Enum.map(fn entry ->
              if is_map(entry), do: entry["name"], else: nil
            end)
            |> Enum.reject(&is_nil/1)

          _ ->
            []
        end

      agent_kind_names =
        case parsed["agent_kinds"] do
          list when is_list(list) ->
            list
            |> Enum.map(fn entry ->
              if is_map(entry), do: entry["name"], else: nil
            end)
            |> Enum.reject(&is_nil/1)

          _ ->
            []
        end

      {:ok, name, channel_names, agent_kind_names}
    else
      _ -> :error
    end
  end

  # ------------------------------------------------------------------
  # Path helpers
  # ------------------------------------------------------------------

  defp default_bundles_root do
    # `__DIR__` for this file is `runtime/lib/mix/tasks/`. Walk up to
    # `runtime/lib/esr/bundles/`. Mirrors Esr.Paths.bundles_dir/0 (the
    # Phase 8 fix landed in the same PR as this task).
    Esr.Paths.bundles_dir()
  end

  defp default_plugins_root do
    # `runtime/lib/esr/plugins/` — sibling of `runtime/lib/esr/bundles/`.
    # Esr.Plugin.Loader has a similar @default_root attribute.
    Esr.Plugin.Loader.default_root()
  end

  defp list_bundle_dirs(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.map(fn e -> Path.join(root, e) end)
        |> Enum.filter(&File.dir?/1)

      {:error, _} ->
        []
    end
  end
end

defmodule Esr.Bundle.Loader do
  @moduledoc """
  Discover bundles on disk + register them in `Esr.Bundle.Registry` and
  their parsed templates in `Esr.SessionTemplate.Registry`.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §5.3, §5.5. Phase 4 (Task 4.3).

  ## Inputs

  Two roots:

    1. **In-tree bundles** under `Esr.Paths.bundles_dir/0`. Each
       subdirectory is one bundle: `<name>/manifest.yaml` +
       `<name>/template.yaml`.
    2. **Operator session templates** under
       `Esr.Paths.session_templates_dir/0`. Each `*.yaml` is a
       standalone conflated manifest+template per spec §5.3 "Operator
       ad-hoc templates" — the file IS the template body, with
       `dependencies:` inline.

  ## Lifecycle

    * `load_all/1` — boot-time entry. Walks both roots, registers
      everything that validates. Loud-fail with Logger.warning naming
      the bundle/file + the failure reason; never aborts the loader.
    * `load_path/1` — `/plugin:install` entry. Same logic for one
      directory.
    * `unload/1` — `/plugin:disable` entry. Removes from both registries.
    * `revalidate_on_plugin_enable/1` — when a plugin enables, retry
      every bundle whose dependencies include the newly-enabled plugin
      and which wasn't successfully registered last time.

  ## Dependency check

  A bundle's `dependencies.plugins[]` is checked against
  `Application.get_env(:esr, :enabled_plugins, [])` (the canonical
  enabled-list source per `Esr.Application.load_enabled_plugins/0`).
  Missing → bundle's manifest IS registered (so we can list it +
  retry on enable cycle), but its template is NOT registered. Loud
  log via `Logger.warning`.
  """

  require Logger

  alias Esr.Bundle
  alias Esr.SessionTemplate

  @doc """
  Walk the in-tree bundles dir + the operator session_templates dir
  and register everything that validates.

  Idempotent: re-running re-registers the same bundles (same content)
  + re-attempts skipped templates.

  Opts:
    * `:bundles_dir` — override the in-tree path (test fixture)
    * `:session_templates_dir` — override the operator path (test fixture)
    * `:enabled_plugins` — override the enabled list (test fixture)
  """
  @spec load_all(keyword()) :: :ok
  def load_all(opts \\ []) do
    bundles_dir = Keyword.get(opts, :bundles_dir, Esr.Paths.bundles_dir())
    operator_dir = Keyword.get(opts, :session_templates_dir, Esr.Paths.session_templates_dir())
    enabled = Keyword.get(opts, :enabled_plugins, current_enabled_plugins())

    load_bundles_dir(bundles_dir, enabled)
    load_operator_dir(operator_dir, enabled)
    :ok
  end

  @doc """
  Install entry for `/plugin:install <path>`. Same logic as `load_all`
  but for one bundle directory.

  Returns `{:ok, %{name, template_registered}}` on success or
  `{:error, reason}` on failure.

  `template_registered` is `false` when the manifest validates but
  dependencies aren't met yet — the bundle is registered, the template
  isn't (will be retried via `revalidate_on_plugin_enable/1`).
  """
  @spec load_path(Path.t(), keyword()) ::
          {:ok, %{name: String.t(), template_registered: boolean()}} | {:error, term()}
  def load_path(path, opts \\ []) do
    enabled = Keyword.get(opts, :enabled_plugins, current_enabled_plugins())
    do_load_one_bundle(path, enabled)
  end

  @doc """
  Remove `bundle_name`'s manifest from `Esr.Bundle.Registry` and its
  template (if any) from `Esr.SessionTemplate.Registry`.
  """
  @spec unload(String.t()) :: :ok
  def unload(bundle_name) when is_binary(bundle_name) do
    template_name =
      case Bundle.Registry.lookup(bundle_name) do
        {:ok, %{source_path: path}} -> template_name_from_dir(path) || bundle_name
        :not_found -> bundle_name
      end

    Bundle.Registry.unregister(bundle_name)
    # Only unregister the template if it was sourced from THIS bundle.
    case SessionTemplate.Registry.lookup(template_name) do
      {:ok, _} ->
        # Look at the source attribution to avoid clobbering an operator
        # template that happens to share the name.
        attribution =
          SessionTemplate.Registry.list_all()
          |> Enum.find(&(&1.name == template_name))

        case attribution do
          %{source: {:bundle, ^bundle_name}} ->
            SessionTemplate.Registry.unregister(template_name)

          _ ->
            :ok
        end

      :not_found ->
        :ok
    end

    :ok
  end

  @doc """
  Re-walk the in-tree bundles dir + operator dir and retry registration
  for any bundle whose dependencies include `plugin_name` and whose
  template wasn't registered last time. Called from `Esr.Plugin.Loader`
  on plugin-enable transitions (Phase 5+).
  """
  @spec revalidate_on_plugin_enable(String.t(), keyword()) :: :ok
  def revalidate_on_plugin_enable(plugin_name, opts \\ []) when is_binary(plugin_name) do
    enabled = Keyword.get(opts, :enabled_plugins, current_enabled_plugins())

    Bundle.Registry.list_all()
    |> Enum.each(fn name ->
      case Bundle.Registry.lookup(name) do
        {:ok, %{manifest: m, source_path: path}} ->
          if plugin_name in m.dependencies.plugins do
            # Already registered? skip. Else retry.
            template_name = template_name_from_dir(path) || name

            case SessionTemplate.Registry.lookup(template_name) do
              {:ok, _} -> :ok
              :not_found -> do_load_one_bundle(path, enabled)
            end
          end

        :not_found ->
          :ok
      end
    end)

    :ok
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp current_enabled_plugins do
    Application.get_env(:esr, :enabled_plugins, [])
    |> Enum.map(&to_string/1)
  end

  defp load_bundles_dir(root, enabled) do
    case File.ls(root) do
      {:ok, entries} ->
        for entry <- Enum.sort(entries) do
          dir = Path.join(root, entry)
          if File.dir?(dir), do: do_load_one_bundle(dir, enabled), else: :ok
        end

        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("bundle loader: cannot read bundles dir #{root}: #{inspect(reason)}")
        :ok
    end
  end

  defp load_operator_dir(root, enabled) do
    case File.ls(root) do
      {:ok, entries} ->
        for entry <- Enum.sort(entries),
            String.ends_with?(entry, ".yaml") or String.ends_with?(entry, ".yml") do
          path = Path.join(root, entry)
          if File.regular?(path), do: do_load_operator_template(path, enabled), else: :ok
        end

        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "bundle loader: cannot read session_templates dir #{root}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Load a single in-tree bundle directory. Returns
  # `{:ok, %{name, template_registered}}` or `{:error, reason}`.
  defp do_load_one_bundle(dir, enabled) do
    manifest_path = Path.join(dir, "manifest.yaml")
    template_path = Path.join(dir, "template.yaml")

    cond do
      not File.regular?(manifest_path) ->
        Logger.warning("bundle loader: missing manifest.yaml at #{dir}; skipping")
        {:error, {:missing_manifest, dir}}

      not File.regular?(template_path) ->
        Logger.warning("bundle loader: missing template.yaml at #{dir}; skipping")
        {:error, {:missing_template, dir}}

      true ->
        with {:ok, manifest} <- parse_manifest(manifest_path),
             :ok <- Bundle.Registry.register(manifest.name, manifest, dir) do
          missing = missing_plugin_deps(manifest, enabled)

          if missing == [] do
            register_bundle_template(manifest, template_path)
          else
            Logger.warning(
              "bundle loader: bundle '#{manifest.name}' missing plugin deps " <>
                "#{inspect(missing)} — manifest registered, template skipped " <>
                "until plugin(s) enabled"
            )

            {:ok, %{name: manifest.name, template_registered: false}}
          end
        end
    end
  end

  defp parse_manifest(path) do
    case Esr.Bundle.Manifest.parse(path) do
      {:ok, m} ->
        {:ok, m}

      {:error, reason} ->
        Logger.warning("bundle loader: manifest parse failed at #{path}: #{inspect(reason)}")
        {:error, {:manifest_invalid, reason, path}}
    end
  end

  defp register_bundle_template(manifest, template_path) do
    case File.read(template_path) do
      {:ok, content} ->
        case SessionTemplate.Parser.parse(content,
               dependencies: manifest.dependencies,
               verify_channels: false,
               verify_flow_nodes: false
             ) do
          {:ok, %SessionTemplate{} = template} ->
            template_name = template.name || manifest.name

            SessionTemplate.Registry.register(template_name, template,
              source: {:bundle, manifest.name}
            )

            Logger.info(
              "bundle loader: registered bundle=#{manifest.name} " <>
                "template=#{template_name}"
            )

            {:ok, %{name: manifest.name, template_registered: true}}

          {:error, reason} ->
            Logger.warning(
              "bundle loader: template parse failed for bundle=#{manifest.name}: " <>
                "#{inspect(reason)}"
            )

            {:error, {:template_invalid, reason, template_path}}
        end

      {:error, reason} ->
        Logger.warning("bundle loader: cannot read template.yaml at #{template_path}: #{inspect(reason)}")
        {:error, {:template_unreadable, reason, template_path}}
    end
  end

  defp missing_plugin_deps(manifest, enabled) do
    enabled_set = MapSet.new(enabled)

    manifest.dependencies.plugins
    |> Enum.reject(&MapSet.member?(enabled_set, &1))
  end

  # Load one operator-shipped standalone yaml. The yaml conflates
  # manifest + template; we read `dependencies:` from the body and
  # `name:` from the body too (no manifest separately).
  defp do_load_operator_template(path, enabled) do
    case File.read(path) do
      {:ok, content} ->
        case SessionTemplate.Parser.parse(content) do
          {:ok, %SessionTemplate{name: name} = template} when is_binary(name) and name != "" ->
            missing =
              template.dependencies.plugins
              |> Enum.reject(&MapSet.member?(MapSet.new(enabled), &1))

            if missing == [] do
              SessionTemplate.Registry.register(name, template, source: :operator)

              Logger.info(
                "bundle loader: registered operator template=#{name} from #{path}"
              )

              {:ok, name}
            else
              Logger.warning(
                "bundle loader: operator template '#{name}' missing plugin deps " <>
                  "#{inspect(missing)} — skipping"
              )

              {:error, {:plugin_deps_unmet, missing}}
            end

          {:ok, %SessionTemplate{name: nil_or_empty}} ->
            Logger.warning(
              "bundle loader: operator template at #{path} has no `name:` field — skipping " <>
                "(got #{inspect(nil_or_empty)})"
            )

            {:error, {:operator_template_missing_name, path}}

          {:error, reason} ->
            Logger.warning(
              "bundle loader: operator template parse failed at #{path}: #{inspect(reason)}"
            )

            {:error, {:operator_template_invalid, reason, path}}
        end

      {:error, reason} ->
        Logger.warning("bundle loader: cannot read operator template at #{path}: #{inspect(reason)}")
        {:error, {:operator_template_unreadable, reason, path}}
    end
  end

  # Read manifest.yaml from a known-bundle dir to recover its template name
  # at unload time. Returns nil on any failure (caller falls back to bundle name).
  defp template_name_from_dir(dir) do
    template_path = Path.join(dir, "template.yaml")

    with true <- File.regular?(template_path),
         {:ok, content} <- File.read(template_path),
         {:ok, %{"name" => name}} <- YamlElixir.read_from_string(content) do
      name
    else
      _ -> nil
    end
  end
end

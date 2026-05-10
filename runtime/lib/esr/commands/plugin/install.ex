defmodule Esr.Commands.Plugin.Install do
  @moduledoc """
  `/plugin install <local_path>` — copy a plugin OR a bundle from a
  local source directory into the in-tree path and validate its
  manifest.

  Track 0 Task 0.6 (plugins) + SessionTemplate spec
  2026-05-10-session-template-and-channel.md Phase 4 Task 4.5
  (bundles).

  ## Two install paths, one slash

  The slash dispatches based on the source directory's shape:

    * **Plugin path** — `manifest.yaml` present, NO `template.yaml`.
      Copy to `runtime/lib/esr/plugins/<name>/`. (Existing behavior;
      unchanged.)
    * **Bundle path** — `manifest.yaml` AND `template.yaml` present.
      Copy to `runtime/lib/esr/bundles/<name>/`. Validate both via
      `Esr.Bundle.Manifest` + `Esr.SessionTemplate.Parser`. Register
      via `Esr.Bundle.Loader.load_path/2` (which adds the bundle to
      `Esr.Bundle.Registry` and — if dependency plugins are enabled —
      its template to `Esr.SessionTemplate.Registry`).
    * **Conflict** — source has `template.yaml` AND its `manifest.yaml`
      ALSO carries plugin-only fields (`channels:`, `declares.agent_kinds:`,
      etc.) — rejected with `bundle_and_plugin_conflict`. Per spec §5.5
      step 3.

  Reject early on: missing source, missing manifest, malformed
  manifest, name collision at target.
  """

  use Esr.Commands.Meta

  command :plugin_install do
    slash         "/plugin:install"
    category      "Plugins"
    description   "从本地路径安装 plugin 或 bundle（Phase 1 only local-path）"
    permission    "plugin/manage"
    requires_user_binding      false
    requires_workspace_binding false

    arg :source, required: true, doc: "local plugin or bundle source directory"
  end

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(cmd) do
    source = cmd["args"]["source"] || cmd[:args][:source] || ""

    text =
      cond do
        source == "" ->
          "usage: /plugin install <local_path>"

        not File.dir?(source) ->
          "source not found or not a directory: #{source}"

        not File.regular?(Path.join(source, "manifest.yaml")) ->
          "no manifest.yaml at #{source}"

        true ->
          do_install(source)
      end

    {:ok, %{"text" => text}}
  end

  defp do_install(source) do
    if File.regular?(Path.join(source, "template.yaml")) do
      install_bundle(source)
    else
      install_plugin(source)
    end
  end

  # ------------------------------------------------------------------
  # Plugin path (existing behavior)
  # ------------------------------------------------------------------

  defp install_plugin(source) do
    manifest_path = Path.join(source, "manifest.yaml")

    case Esr.Plugin.Manifest.parse(manifest_path) do
      {:ok, manifest} ->
        target = plugins_dir() |> Path.join(manifest.name)

        if File.exists?(target) do
          "plugin already installed at #{target}\n" <>
            "(remove existing dir first if you want to replace it)"
        else
          case copy_tree(source, target) do
            :ok ->
              "installed plugin: #{manifest.name} v#{manifest.version} at #{target}\n" <>
                "next: enable via `/plugin enable #{manifest.name}` " <>
                "then `mix compile` + restart esrd"

            {:error, reason} ->
              "copy failed: #{inspect(reason)}"
          end
        end

      {:error, reason} ->
        "manifest invalid: #{inspect(reason)}"
    end
  end

  # ------------------------------------------------------------------
  # Bundle path (Task 4.5)
  # ------------------------------------------------------------------

  defp install_bundle(source) do
    manifest_path = Path.join(source, "manifest.yaml")

    with :ok <- detect_bundle_plugin_conflict(manifest_path),
         {:ok, manifest} <- parse_bundle_manifest(manifest_path) do
      target = bundles_dir() |> Path.join(manifest.name)

      if File.exists?(target) do
        "bundle already installed at #{target}\n" <>
          "(remove existing dir first if you want to replace it)"
      else
        case copy_tree(source, target) do
          :ok ->
            register_after_copy(manifest, target)

          {:error, reason} ->
            "copy failed: #{inspect(reason)}"
        end
      end
    else
      {:error, {:bundle_and_plugin_conflict, fields}} ->
        "bundle_and_plugin_conflict: source contains template.yaml AND manifest " <>
          "carries plugin-only fields #{inspect(fields)}. Pick one — a directory " <>
          "is either a plugin (no template.yaml) or a bundle (template.yaml + " <>
          "minimal manifest)."

      {:error, reason} ->
        "bundle manifest invalid: #{inspect(reason)}"
    end
  end

  defp parse_bundle_manifest(manifest_path) do
    case Esr.Bundle.Manifest.parse(manifest_path) do
      {:ok, m} -> {:ok, m}
      {:error, reason} -> {:error, reason}
    end
  end

  # Spec §5.5 step 3: a directory cannot be both a bundle and a
  # plugin. We detect this by reading the raw yaml and looking for
  # plugin-only top-level keys when template.yaml is present.
  #
  # Plugin-shape keys: `channels:` (top-level list), `declares:`
  # (containing `agent_kinds`, `entities`, `slash_routes`, etc), or
  # `agent_kinds:` (top-level if a future spec promotes it).
  defp detect_bundle_plugin_conflict(manifest_path) do
    case File.read(manifest_path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, %{} = parsed} ->
            offenders =
              [:channels, :declares, :agent_kinds]
              |> Enum.filter(fn k ->
                v = parsed[Atom.to_string(k)]
                v != nil and v != [] and v != %{}
              end)

            case offenders do
              [] -> :ok
              fields -> {:error, {:bundle_and_plugin_conflict, fields}}
            end

          _ ->
            :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp register_after_copy(manifest, target) do
    case Esr.Bundle.Loader.load_path(target) do
      {:ok, %{name: name, template_registered: true}} ->
        "installed bundle: #{name} v#{manifest.version} at #{target}\n" <>
          "template registered (dependencies satisfied)\n" <>
          "next: `/session:new template=#{name} name=<your_session>`"

      {:ok, %{name: name, template_registered: false}} ->
        missing_plugins =
          manifest.dependencies.plugins
          |> Enum.reject(fn p -> p in current_enabled_plugins() end)

        "installed bundle: #{name} v#{manifest.version} at #{target}\n" <>
          "manifest registered, template SKIPPED (missing plugins: " <>
          "#{inspect(missing_plugins)})\n" <>
          "enable the missing plugin(s) first, then this template will register " <>
          "automatically (revalidate_on_plugin_enable)"

      {:error, reason} ->
        "bundle registration failed: #{inspect(reason)}\n" <>
          "(directory copied to #{target} — remove it manually if you want a clean retry)"
    end
  end

  # ------------------------------------------------------------------
  # Shared helpers
  # ------------------------------------------------------------------

  defp copy_tree(source, target) do
    with :ok <- File.mkdir_p(Path.dirname(target)) do
      File.cp_r(source, target)
      |> case do
        {:ok, _} -> :ok
        {:error, reason, _path} -> {:error, reason}
      end
    end
  end

  defp plugins_dir do
    # Test-time override via Application env; default is the in-tree
    # `runtime/lib/esr/plugins/` resolved relative to this module.
    Application.get_env(:esr, :plugin_install_plugins_dir) ||
      Path.expand("../../plugins", __DIR__)
  end

  defp bundles_dir do
    # Mirror plugins_dir/0 — same up-2-levels resolution + same env override.
    Application.get_env(:esr, :plugin_install_bundles_dir) ||
      Path.expand("../../bundles", __DIR__)
  end

  defp current_enabled_plugins do
    Application.get_env(:esr, :enabled_plugins, [])
    |> Enum.map(&to_string/1)
  end
end

defmodule Esr.Admin.Commands.Plugin.Install do
  @moduledoc """
  `/plugin install <local_path>` — copy a plugin from a local source
  directory into `runtime/lib/esr/plugins/<name>/` and validate its
  manifest.

  Track 0 Task 0.6. Phase-1 supports local-path installs only; hex /
  git remote installs are Phase-2 work (per Spec B §2 non-goals).

  ## Behavior

  1. Source path must exist and contain `manifest.yaml`.
  2. Parse manifest to learn `name`. Reject if a plugin with that name
     already lives at the target.
  3. `cp -R` source → `runtime/lib/esr/plugins/<name>/`.
  4. Compile (we delegate to a `mix compile` invocation by the
     operator — running mix from inside the BEAM is fragile and the
     restart hint covers it).
  5. Report success + restart-required hint.

  Reject early on: missing source, missing manifest, malformed
  manifest, plugin name collision.
  """

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

  defp copy_tree(source, target) do
    with :ok <- File.mkdir_p(Path.dirname(target)) do
      File.cp_r(source, target)
      |> case do
        {:ok, _} -> :ok
        {:error, reason, _path} -> {:error, reason}
      end
    end
  end

  # Resolve the plugins root the same way Esr.Plugin.Loader does
  # (`runtime/lib/esr/plugins/`). We mirror the path expansion rather
  # than calling into Loader internals.
  defp plugins_dir do
    Path.expand("../../../plugins", __DIR__)
  end
end

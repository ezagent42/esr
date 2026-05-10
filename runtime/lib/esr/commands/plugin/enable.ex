defmodule Esr.Commands.Plugin.Enable do
  @moduledoc """
  `/plugin enable <name>` — add `name` to plugins.yaml.

  Track 0 Task 0.6. Phase-1 takes effect after restart (we don't
  hot-load plugins yet — Phase 2 territory).
  """

  use Esr.Commands.Meta

  command :plugin_enable do
    slash         "/plugin:enable"
    category      "Plugins"
    description   "启用 plugin（写 plugins.yaml；重启生效）"
    permission    "plugin/manage"
    requires_user_binding      false
    requires_workspace_binding false

    arg :name, required: true, doc: "plugin name"
  end

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, term()}

  @spec execute(map()) :: result()
  def execute(cmd) do
    name = cmd["args"]["name"] || cmd[:args][:name] || ""

    cond do
      name == "" ->
        {:ok, %{"text" => "usage: /plugin enable <name>"}}

      not plugin_exists?(name) ->
        {:ok,
         %{"text" => "plugin not installed: #{name}\n(install first via `/plugin install`)"}}

      true ->
        case Esr.Plugin.PluginsYaml.enable(name) do
          :ok ->
            # Phase 5 Task 5.4: re-attempt registering bundles whose
            # template registration was deferred because they declared a
            # dependency on `name`. Until plugins go hot-enable
            # (restart-required today), this also nudges the in-memory
            # enabled-plugins list so a re-check happens in the same
            # esrd lifecycle. The re-check reads
            # `Application.get_env(:esr, :enabled_plugins, [])` so we
            # update it before invoking. Idempotent: bundles already
            # registered are skipped by Bundle.Loader's revalidate.
            sync_enabled_plugins_app_env(name)
            _ = Esr.Bundle.Loader.revalidate_on_plugin_enable(name)

            {:ok,
             %{
               "text" =>
                 "enabled plugin: #{name}\nrestart esrd to load: " <>
                   "`scripts/esrd.sh restart`"
             }}

          {:error, reason} ->
            {:ok, %{"text" => "failed to write plugins.yaml: #{inspect(reason)}"}}
        end
    end
  end

  # Ensure the in-process enabled list reflects the just-written
  # plugins.yaml so `Esr.Bundle.Loader.revalidate_on_plugin_enable/1`
  # sees `name` as enabled. This is a forward compatibility hook for
  # the eventual hot-enable migration; today plugins still require
  # restart for actual loading, but the bundle revalidation is a
  # config-only operation that can run earlier.
  defp sync_enabled_plugins_app_env(name) do
    current =
      Application.get_env(:esr, :enabled_plugins, [])
      |> Enum.map(&to_string/1)

    if name in current do
      :ok
    else
      Application.put_env(:esr, :enabled_plugins, current ++ [name])
    end
  end

  defp plugin_exists?(name) do
    case Esr.Plugin.Loader.discover() do
      {:ok, plugins} -> Enum.any?(plugins, fn {n, _} -> n == name end)
      _ -> false
    end
  end
end

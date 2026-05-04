defmodule Esr.Admin.Commands.Plugin.Enable do
  @moduledoc """
  `/plugin enable <name>` — add `name` to plugins.yaml.

  Track 0 Task 0.6. Phase-1 takes effect after restart (we don't
  hot-load plugins yet — Phase 2 territory).
  """

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

  defp plugin_exists?(name) do
    case Esr.Plugin.Loader.discover() do
      {:ok, plugins} -> Enum.any?(plugins, fn {n, _} -> n == name end)
      _ -> false
    end
  end
end

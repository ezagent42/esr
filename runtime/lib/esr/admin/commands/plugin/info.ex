defmodule Esr.Admin.Commands.Plugin.Info do
  @moduledoc """
  `/plugin info <name>` — dump a plugin's manifest summary.

  Track 0 Task 0.6.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(cmd) do
    name = cmd["args"]["name"] || cmd[:args][:name] || ""

    text =
      case Esr.Plugin.Loader.discover() do
        {:ok, plugins} ->
          case Enum.find(plugins, fn {n, _} -> n == name end) do
            nil ->
              "plugin not found: #{name}\n(use `/plugin list` to see installed plugins)"

            {_, manifest} ->
              render(manifest)
          end

        {:error, reason} ->
          "plugin discovery failed: #{inspect(reason)}"
      end

    {:ok, %{"text" => text}}
  end

  defp render(manifest) do
    declares = manifest.declares
    caps = Map.get(declares, :capabilities, [])
    entities = Map.get(declares, :entities, [])
    sidecars = Map.get(declares, :python_sidecars, [])

    """
    plugin: #{manifest.name} v#{manifest.version}
    #{manifest.description}

    depends_on:
      core: #{manifest.depends_on.core}
      plugins: #{inspect(manifest.depends_on.plugins)}

    declares:
      capabilities: #{Enum.count(caps)}
      entities: #{Enum.count(entities)}
      python_sidecars: #{Enum.count(sidecars)}
    """
    |> String.trim_trailing()
  end
end

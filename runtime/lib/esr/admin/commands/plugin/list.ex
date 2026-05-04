defmodule Esr.Admin.Commands.Plugin.List do
  @moduledoc """
  `/plugin list` — show every plugin discovered on disk plus its
  enabled/disabled state.

  Track 0 Task 0.6.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(_cmd) do
    enabled_set =
      :esr
      |> Application.get_env(:enabled_plugins, [])
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    text =
      case Esr.Plugin.Loader.discover() do
        {:ok, []} ->
          "no plugins installed\n(install via `/plugin install <local_path>`)"

        {:ok, plugins} ->
          rows =
            Enum.map_join(plugins, "\n", fn {name, manifest} ->
              state = if MapSet.member?(enabled_set, name), do: "enabled", else: "disabled"
              "  - #{name} v#{manifest.version} [#{state}]"
            end)

          "installed plugins:\n#{rows}"

        {:error, reason} ->
          "plugin discovery failed: #{inspect(reason)}"
      end

    {:ok, %{"text" => text}}
  end
end

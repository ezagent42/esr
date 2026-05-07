defmodule Esr.Commands.Plugin.ListConfig do
  @moduledoc """
  `/plugin:list-config`

  Show effective config for all enabled plugins.

  Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §6.
  """

  @behaviour Esr.Role.Control

  alias Esr.Plugin.Config
  alias Esr.Plugin.EnabledList

  @impl Esr.Role.Control
  def execute(_cmd) do
    global_path = Esr.Paths.global_plugins_yaml()
    enabled = EnabledList.read(global_path)

    text =
      enabled
      |> Enum.map(fn plugin_name ->
        config = Config.resolve(plugin_name, global_path: global_path)

        if map_size(config) == 0 do
          "#{plugin_name}: (no config)"
        else
          rows =
            config
            |> Enum.sort_by(fn {k, _} -> k end)
            |> Enum.map_join("\n", fn {k, v} -> "    #{k} = #{inspect(v)}" end)

          "#{plugin_name}:\n#{rows}"
        end
      end)
      |> Enum.join("\n\n")

    {:ok, %{"text" => "Plugin effective config:\n\n#{text}"}}
  end
end

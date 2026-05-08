defmodule Esr.Commands.Plugin.ShowConfig do
  @moduledoc """
  `/plugin:show-config <plugin> [layer=effective|global|user|workspace]`

  Show plugin config at the specified layer (default: effective = merged result).

  Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §6.
  """

  @behaviour Esr.Role.Control

  alias Esr.Plugin.Config

  @impl Esr.Role.Control
  def execute(%{"args" => args} = _cmd) do
    plugin_name = args["plugin"]
    layer_str = args["layer"] || "effective"

    path_opts = build_path_opts(args)

    config =
      case layer_str do
        "effective" ->
          Config.resolve(plugin_name, path_opts)

        layer when layer in ~w(global user workspace) ->
          layer_opt_key = :"#{layer}_path"
          path = Keyword.get(path_opts, layer_opt_key)
          if path, do: Config.resolve(plugin_name, [{layer_opt_key, path}]), else: %{}

        _ ->
          %{}
      end

    text = render_config(plugin_name, layer_str, config)
    {:ok, %{"text" => text}}
  end

  defp build_path_opts(args) do
    [
      global_path: args["_global_path_override"] || Esr.Paths.global_plugins_yaml(),
      user_path: args["_user_path_override"],
      workspace_path: args["_workspace_path_override"]
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  defp render_config(plugin_name, layer, config) when map_size(config) == 0 do
    "#{plugin_name} config [#{layer}]: (empty)"
  end

  defp render_config(plugin_name, layer, config) do
    rows =
      config
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join("\n", fn {k, v} -> "  #{k} = #{inspect(v)}" end)

    "#{plugin_name} config [#{layer}]:\n#{rows}"
  end
end

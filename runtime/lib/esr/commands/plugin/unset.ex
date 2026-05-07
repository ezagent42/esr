defmodule Esr.Commands.Plugin.Unset do
  @moduledoc """
  `/plugin:unset <plugin> key [layer=global|user|workspace]`

  Removes a config key from the specified layer's plugins.yaml.
  Idempotent. Default layer: global.

  Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §6.
  """

  @behaviour Esr.Role.Control

  alias Esr.Plugin.Config
  alias Esr.Plugin.Loader

  @valid_layers ~w(global user workspace)

  @impl Esr.Role.Control
  def execute(%{"args" => args} = _cmd) do
    plugin_name = args["plugin"]
    key = args["key"]
    layer_str = args["layer"] || "global"

    with {:ok, _manifest} <- resolve_manifest(plugin_name),
         {:ok, layer} <- parse_layer(layer_str),
         {:ok, path_opts} <- resolve_path_opts(layer, args) do
      delete_opts = [{:layer, layer} | path_opts]
      :ok = Config.delete_layer(plugin_name, key, delete_opts)

      {:ok,
       %{
         "text" =>
           "config key #{key} removed from #{plugin_name} [#{layer_str}]; restart esrd to apply"
       }}
    end
  end

  defp resolve_manifest(plugin_name) do
    case Loader.discover() do
      {:ok, manifests} ->
        case Enum.find(manifests, fn {name, _} -> name == plugin_name end) do
          nil -> {:error, %{"type" => "unknown_plugin", "plugin" => plugin_name}}
          {_, manifest} -> {:ok, manifest}
        end

      {:error, reason} ->
        {:error, %{"type" => "discovery_failed", "reason" => inspect(reason)}}
    end
  end

  defp parse_layer(layer_str) when layer_str in @valid_layers,
    do: {:ok, String.to_atom(layer_str)}

  defp parse_layer(layer_str) do
    {:error, %{"type" => "invalid_layer", "layer" => layer_str, "valid" => @valid_layers}}
  end

  defp resolve_path_opts(:global, args) do
    path = args["_global_path_override"] || Esr.Paths.global_plugins_yaml()
    {:ok, [global_path: path]}
  end

  defp resolve_path_opts(:user, args) do
    user_uuid = args["user_uuid"]

    if is_binary(user_uuid) and user_uuid != "" do
      path = args["_user_path_override"] || Esr.Paths.user_plugins_yaml(user_uuid)
      {:ok, [user_path: path]}
    else
      {:error, %{"type" => "user_uuid_required"}}
    end
  end

  defp resolve_path_opts(:workspace, args) do
    workspace_id = args["workspace_id"]

    if is_binary(workspace_id) and workspace_id != "" do
      path = args["_workspace_path_override"] || workspace_plugins_yaml(workspace_id)
      {:ok, [workspace_path: path]}
    else
      {:error, %{"type" => "workspace_id_required"}}
    end
  end

  defp workspace_plugins_yaml(workspace_id) do
    case Esr.Resource.Workspace.Registry.lookup(workspace_id) do
      {:ok, ws} -> Path.join([ws.folders |> List.first(""), ".esr", "plugins.yaml"])
      _ -> raise "workspace not found: #{workspace_id}"
    end
  end
end

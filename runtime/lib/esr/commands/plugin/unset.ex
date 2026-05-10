defmodule Esr.Commands.Plugin.Unset do
  @moduledoc """
  `/plugin:unset <plugin> key [layer=global|user|workspace]`

  Removes a config key from the specified layer's plugins.yaml.
  Idempotent. Default layer: global.

  Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §6.
  """

  use Esr.Commands.Meta

  command :plugin_unset do
    slash         "/plugin:unset"
    category      "Plugins"
    description   "删除 plugin config key（幂等；重启生效）"
    permission    "plugin/manage"
    requires_user_binding      false
    requires_workspace_binding false

    arg :plugin, required: true,  doc: "plugin name"
    arg :key,    required: true,  doc: "config key"
    arg :layer,  required: false, doc: "global | user | workspace (default: global)"

    error :unknown_plugin,        "plugin %{plugin} not found"
    error :discovery_failed,      "plugin discovery failed: %{reason}"
    error :invalid_layer,         "invalid layer %{layer}; valid: %{valid}"
    error :user_uuid_required,    "layer=user requires user_uuid"
    error :workspace_id_required, "layer=workspace requires workspace_id"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Plugin.Config
  alias Esr.Plugin.Loader

  @valid_layers ~w(global user workspace)

  # Phase 5 Task 5.3: virtual plugin namespaces (no on-disk manifest)
  # also need a `/plugin:unset` path symmetric to `/plugin:set`. The
  # `session` namespace is the first; future ones extend the list.
  @virtual_namespaces ~w(session)

  def execute(%{"args" => args} = _cmd) do
    plugin_name = args["plugin"]
    key = args["key"]
    layer_str = args["layer"] || "global"

    cond do
      plugin_name in @virtual_namespaces ->
        with {:ok, layer} <- parse_layer(layer_str),
             {:ok, path_opts} <- resolve_path_opts(layer, args) do
          delete_opts = [{:layer, layer} | path_opts]
          :ok = Config.delete_layer(plugin_name, key, delete_opts)

          {:ok,
           %{
             "text" => "config key #{key} removed from #{plugin_name} [#{layer_str}]"
           }}
        end

      true ->
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
  end

  defp resolve_manifest(plugin_name) do
    case Loader.discover() do
      {:ok, manifests} ->
        case Enum.find(manifests, fn {name, _} -> name == plugin_name end) do
          nil ->
            Render.error(__MODULE__.command_meta(), :unknown_plugin, %{plugin: plugin_name})

          {_, manifest} ->
            {:ok, manifest}
        end

      {:error, reason} ->
        Render.error(__MODULE__.command_meta(), :discovery_failed, %{reason: inspect(reason)})
    end
  end

  defp parse_layer(layer_str) when layer_str in @valid_layers,
    do: {:ok, String.to_atom(layer_str)}

  defp parse_layer(layer_str) do
    Render.error(__MODULE__.command_meta(), :invalid_layer, %{
      layer: layer_str,
      valid: inspect(@valid_layers)
    })
  end

  defp resolve_path_opts(:global, args) do
    plugin_name = args["plugin"]
    path = args["_global_path_override"] || Esr.Paths.plugin_global_dir(plugin_name)
    {:ok, [global_path: path]}
  end

  defp resolve_path_opts(:user, args) do
    plugin_name = args["plugin"]
    user_uuid = args["user_uuid"]

    if is_binary(user_uuid) and user_uuid != "" do
      path = args["_user_path_override"] || Esr.Paths.plugin_user_dir(plugin_name, user_uuid)
      {:ok, [user_path: path]}
    else
      Render.error(__MODULE__.command_meta(), :user_uuid_required)
    end
  end

  defp resolve_path_opts(:workspace, args) do
    plugin_name = args["plugin"]
    workspace_id = args["workspace_id"]

    if is_binary(workspace_id) and workspace_id != "" do
      path = args["_workspace_path_override"] || workspace_plugin_dir(plugin_name, workspace_id)
      {:ok, [workspace_path: path]}
    else
      Render.error(__MODULE__.command_meta(), :workspace_id_required)
    end
  end

  defp workspace_plugin_dir(plugin_name, workspace_id) do
    case Esr.Resource.Workspace.Registry.lookup(workspace_id) do
      {:ok, ws} ->
        Esr.Paths.plugin_workspace_dir(plugin_name, ws.folders |> List.first(""))

      _ ->
        raise "workspace not found: #{workspace_id}"
    end
  end
end

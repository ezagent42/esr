defmodule Esr.Commands.Plugin.Set do
  @moduledoc """
  `/plugin:set <plugin> key=<k> value=<v> [layer=global|user|workspace]`

  Writes a config key to the specified layer's plugins.yaml.
  Key must be declared in the plugin's manifest config_schema:.
  Default layer: global.

  Returns restart-required hint on success.

  Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §6.
  """

  use Esr.Commands.Meta

  command :plugin_set do
    slash         "/plugin:set"
    category      "Plugins"
    description   "写 plugin config key 到指定 layer（默认 global；重启生效）"
    permission    "plugin/manage"
    requires_user_binding      false
    requires_workspace_binding false

    arg :plugin, required: true,  doc: "plugin name"
    arg :key,    required: true,  doc: "config key (must be declared in plugin manifest config_schema)"
    arg :value,  required: true,  doc: "config value"
    arg :layer,  required: false, doc: "global | user | workspace (default: global)"

    error :unknown_plugin,       "plugin %{plugin} not found"
    error :discovery_failed,     "plugin discovery failed: %{reason}"
    error :no_config_schema,     "plugin %{plugin} declares no config_schema"
    error :unknown_config_key,   "config key %{key} is not declared in plugin manifest config_schema; valid keys: %{valid_keys}"
    error :invalid_layer,        "invalid layer %{layer}; valid: %{valid}"
    error :user_uuid_required,   "layer=user requires user_uuid"
    error :workspace_id_required, "layer=workspace requires workspace_id"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Plugin.Config
  alias Esr.Plugin.Loader

  @valid_layers ~w(global user workspace)

  # Phase 5 Task 5.3: virtual plugin namespaces have no on-disk manifest
  # but operators still need a `/plugin:set plugin=<ns> key=...` path to
  # configure them. The `session` namespace owns `default_template` for
  # SessionTemplate selection (spec §5.4). Each virtual entry maps to the
  # set of declared keys; missing key → unknown_config_key, same as a
  # real plugin's manifest config_schema gate.
  @virtual_namespaces %{
    "session" => MapSet.new(["default_template"])
  }

  def execute(%{"args" => args} = _cmd) do
    plugin_name = args["plugin"]
    key = args["key"]
    value = args["value"]
    layer_str = args["layer"] || "global"

    cond do
      Map.has_key?(@virtual_namespaces, plugin_name) ->
        write_virtual_namespace(plugin_name, key, value, layer_str, args)

      true ->
        with {:ok, manifest} <- resolve_manifest(plugin_name),
             :ok <- validate_config_key(manifest, key),
             {:ok, layer} <- parse_layer(layer_str),
             {:ok, path_opts} <- resolve_path_opts(layer, args) do
          store_opts = [{:layer, layer} | path_opts]
          :ok = Config.store_layer(plugin_name, key, value, store_opts)

          {:ok,
           %{
             "text" =>
               "config written: #{plugin_name}.#{key} = #{inspect(value)} [#{layer_str}]; restart esrd to apply"
           }}
        end
    end
  end

  defp write_virtual_namespace(plugin_name, key, value, layer_str, args) do
    allowed = Map.fetch!(@virtual_namespaces, plugin_name)

    with :ok <- validate_virtual_key(plugin_name, key, allowed),
         {:ok, layer} <- parse_layer(layer_str),
         {:ok, path_opts} <- resolve_path_opts(layer, args) do
      store_opts = [{:layer, layer} | path_opts]
      :ok = Config.store_layer(plugin_name, key, value, store_opts)

      # Virtual namespaces don't require a restart — they don't drive any
      # supervised plugin process. The "session" namespace's
      # default_template is read on every /session:new without restart.
      {:ok,
       %{
         "text" => "config written: #{plugin_name}.#{key} = #{inspect(value)} [#{layer_str}]"
       }}
    end
  end

  defp validate_virtual_key(plugin_name, key, allowed) do
    if MapSet.member?(allowed, key) do
      :ok
    else
      Render.error(__MODULE__.command_meta(), :unknown_config_key, %{
        key: key,
        valid_keys: inspect(MapSet.to_list(allowed))
      })
      |> tap(fn _ -> _ = plugin_name end)
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

  defp validate_config_key(manifest, key) do
    schema = manifest.declares[:config_schema] || %{}

    cond do
      map_size(schema) == 0 ->
        Render.error(__MODULE__.command_meta(), :no_config_schema, %{plugin: manifest.name})

      not Map.has_key?(schema, key) ->
        Render.error(__MODULE__.command_meta(), :unknown_config_key, %{
          key: key,
          valid_keys: inspect(Map.keys(schema))
        })

      true ->
        :ok
    end
  end

  defp parse_layer(layer_str) when layer_str in @valid_layers do
    {:ok, String.to_atom(layer_str)}
  end

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

defmodule Esr.Commands.Plugin.Reload do
  @moduledoc """
  `/plugin:reload <plugin>`

  Triggers a config reload for a single named plugin. The plugin must
  declare `hot_reloadable: true` in its manifest (Q2). The reload is
  best-effort: if the plugin's `on_config_change/1` returns
  `{:error, reason}`, the framework logs a warning and returns a success
  response with `"reloaded" => false, "fallback_active" => true` (Q5).

  No batch form exists (Q7). The `plugin` arg is required; if absent,
  the dispatcher returns a missing-arg error before reaching this module.

  Permission: `plugin/manage` (shared with /plugin:set, per Q6).

  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §4.
  """

  use Esr.Commands.Meta

  command :plugin_reload do
    slash         "/plugin:reload"
    category      "Plugins"
    description   "触发指定 plugin 的 config reload（plugin manifest 必须 hot_reloadable: true；不传 plugin name = 报错，无 batch reload）"
    permission    "plugin/manage"
    requires_user_binding      false
    requires_workspace_binding false

    arg :plugin, required: true, doc: "plugin name"

    error :unknown_plugin,           "plugin %{plugin} not found"
    error :discovery_failed,         "plugin discovery failed: %{reason}"
    error :not_hot_reloadable,       "plugin %{plugin} must declare hot_reloadable: true in manifest to support reload; restart esrd to apply config changes"
    error :plugin_module_not_found,  "expected module %{module} to be loaded for plugin %{plugin}; verify the plugin's Plugin module exists"
    error :callback_not_exported,    "plugin %{plugin} declares hot_reloadable: true but does not export on_config_change/1; check that the module implements Esr.Plugin.Behaviour"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Plugin.Config
  alias Esr.Plugin.ConfigSnapshot
  alias Esr.Plugin.Loader

  require Logger

  @callback_timeout_ms 5_000

  def execute(%{"args" => args} = _cmd) do
    plugin_name = args["plugin"]
    plugin_root = args["_plugin_root_override"]

    with {:ok, manifest} <- resolve_manifest(plugin_name, plugin_root),
         :ok <- check_hot_reloadable(manifest),
         {:ok, module} <- resolve_module(manifest),
         :ok <- check_callback_exported(module, plugin_name),
         {:ok, changed_keys} <- compute_changed_keys(plugin_name, args) do
      invoke_callback(module, plugin_name, changed_keys)
    end
  end

  # ------------------------------------------------------------------
  # Step 1: resolve manifest from disk
  # ------------------------------------------------------------------

  defp resolve_manifest(plugin_name, plugin_root) do
    root = plugin_root || Loader.default_root()

    case Loader.discover(root) do
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

  # ------------------------------------------------------------------
  # Step 2: check hot_reloadable flag in manifest (Q2)
  # ------------------------------------------------------------------

  defp check_hot_reloadable(%{hot_reloadable: true}), do: :ok

  defp check_hot_reloadable(%{name: name}) do
    Render.error(__MODULE__.command_meta(), :not_hot_reloadable, %{plugin: name})
  end

  # ------------------------------------------------------------------
  # Step 3: resolve module from manifest name convention
  # Convention: plugin "claude_code" → Esr.Plugins.ClaudeCode.Plugin
  #             plugin "feishu"      → Esr.Plugins.Feishu.Plugin
  # ------------------------------------------------------------------

  defp resolve_module(%{name: name}) do
    module_name =
      name
      |> String.split(~r/[-_]/)
      |> Enum.map(&String.capitalize/1)
      |> Enum.join()
      |> then(&"Esr.Plugins.#{&1}.Plugin")

    module = Module.concat([module_name])

    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      Render.error(__MODULE__.command_meta(), :plugin_module_not_found, %{
        plugin: name,
        module: module_name
      })
    end
  end

  # ------------------------------------------------------------------
  # Step 4: check on_config_change/1 is exported
  # ------------------------------------------------------------------

  defp check_callback_exported(module, plugin_name) do
    if function_exported?(module, :on_config_change, 1) do
      :ok
    else
      Render.error(__MODULE__.command_meta(), :callback_not_exported, %{plugin: plugin_name})
    end
  end

  # ------------------------------------------------------------------
  # Step 5: compute changed_keys by diffing current config vs snapshot
  # ------------------------------------------------------------------

  defp compute_changed_keys(plugin_name, args) do
    path_opts = path_opts_from_args(args)
    current = Config.resolve(plugin_name, path_opts)
    snapshot = ConfigSnapshot.get(plugin_name)

    changed =
      (Map.keys(current) ++ Map.keys(snapshot))
      |> Enum.uniq()
      |> Enum.filter(fn k -> Map.get(current, k) != Map.get(snapshot, k) end)

    {:ok, changed}
  end

  defp path_opts_from_args(args) do
    plugin_name = args["plugin"]

    [
      global_path:
        args["_global_path_override"] || Esr.Paths.plugin_global_dir(plugin_name),
      user_path: args["_user_path_override"],
      workspace_path: args["_workspace_path_override"]
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  # ------------------------------------------------------------------
  # Step 6: invoke callback in a Task with 5-second timeout (spec §9 Risk 1)
  # Exposed as a public function for test seam access.
  # ------------------------------------------------------------------

  @doc false
  # Public for test access only. Do not call from outside this module in production.
  def invoke_callback(module, plugin_name, changed_keys) do
    task = Task.async(fn -> safe_call(module, changed_keys) end)

    case Task.yield(task, @callback_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        ConfigSnapshot.update(plugin_name)

        {:ok,
         %{
           "plugin" => plugin_name,
           "reloaded" => true,
           "changed_keys" => changed_keys
         }}

      {:ok, {:error, reason}} ->
        Logger.warning(
          "plugin #{plugin_name} failed to apply config change: #{inspect(reason)}"
        )

        {:ok,
         %{
           "plugin" => plugin_name,
           "reloaded" => false,
           "fallback_active" => true,
           "reason" => inspect(reason),
           "changed_keys" => changed_keys
         }}

      nil ->
        Logger.warning(
          "plugin #{plugin_name} on_config_change/1 timed out after #{@callback_timeout_ms}ms"
        )

        {:ok,
         %{
           "plugin" => plugin_name,
           "reloaded" => false,
           "fallback_active" => true,
           "reason" => "callback_timeout",
           "changed_keys" => changed_keys
         }}
    end
  end

  # Wrap the callback so exceptions are caught and returned as {:error, ...}.
  defp safe_call(module, changed_keys) do
    module.on_config_change(changed_keys)
  rescue
    e -> {:error, {:callback_raised, Exception.message(e)}}
  end
end

defmodule Esr.Plugins.Feishu.Plugin do
  @moduledoc """
  Hot-reload opt-in module for the `feishu` plugin.

  Implements `Esr.Plugin.Behaviour.on_config_change/1`.

  ## Config key behavior

    - `app_id`, `app_secret` — consumed by `FeishuAppAdapter` peers when
      making Lark REST API calls. The adapter reads config via
      `Esr.Plugin.Config.get/3` at call time (not cached at start), so
      new values take effect on the next outbound API call automatically.
      No rebinding required.

    - `log_level` — forwarded to the `feishu_adapter_runner` Python
      sidecar at subprocess start. The sidecar does not support live
      log-level changes at runtime. A warning is logged; the operator
      must restart the sidecar to apply the change.

  Return: always `:ok`. The plugin does not enter a fallback state.

  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §8 (HR-3).
  """

  @behaviour Esr.Plugin.Behaviour

  require Logger

  @impl Esr.Plugin.Behaviour
  def on_config_change(changed_keys) do
    if "log_level" in changed_keys do
      Logger.warning(
        "feishu plugin: log_level changed but the feishu_adapter_runner sidecar " <>
          "does not support live log-level changes. " <>
          "Restart the sidecar to apply the new log level."
      )
    end

    # app_id / app_secret: FeishuAppAdapter reads config at call time via
    # Esr.Plugin.Config.get/3, so new values take effect on the next
    # outbound API call automatically. No rebinding needed.
    :ok
  end
end

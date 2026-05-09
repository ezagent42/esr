defmodule Esr.Plugins.Feishu.Plugin do
  @moduledoc """
  Hot-reload opt-in module for the `feishu` plugin.

  Implements `Esr.Plugin.Behaviour.on_config_change/1`.

  ## Config key behavior

    - `log_level` — forwarded to the `feishu_adapter_runner` Python
      sidecar at subprocess start. The sidecar does not support live
      log-level changes at runtime. A warning is logged; the operator
      must restart the sidecar to apply the change.

  Note: `app_id` and `app_secret` are NOT plugin-wide config. They are
  per-instance attributes of one specific Lark App, declared in
  `adapters.yaml` under `instances.<id>.config.{app_id,app_secret}`,
  and flow verbatim into the Python sidecar's `--config-json` payload.
  Phase 7.D (2026-05-08) moved them out of plugin config; this module
  no longer handles them.

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

    :ok
  end
end

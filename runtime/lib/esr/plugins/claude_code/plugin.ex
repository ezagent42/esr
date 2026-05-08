defmodule Esr.Plugins.ClaudeCode.Plugin do
  @moduledoc """
  Hot-reload opt-in module for the `claude_code` plugin.

  Implements `Esr.Plugin.Behaviour.on_config_change/1`.

  ## Config key behavior

  All `claude_code` config keys are spawn-time values — they are
  injected into the PTY environment at session start via
  `Esr.Plugins.ClaudeCode.Launcher.build_env/1` (or equivalent).
  The running `claude` subprocess holds its own copy of the values from
  the time it was launched; hot-reload cannot retroactively change a
  running subprocess's environment.

  Behavior per key:
    - `http_proxy`, `https_proxy`, `no_proxy`, `esrd_url` — new value
      takes effect for the NEXT cc session spawn (no rebind needed).
    - `anthropic_api_key_ref` — new value also takes effect at next spawn.
      A warning is logged because running sessions are unaffected (the
      API key is the session's identity; operators may expect immediate
      effect and be surprised).

  Return: always `:ok`. The plugin does not enter a fallback state — all
  config keys are safe to acknowledge regardless of running session state.

  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §8 (HR-3).
  """

  @behaviour Esr.Plugin.Behaviour

  require Logger

  @impl Esr.Plugin.Behaviour
  def on_config_change(changed_keys) do
    if "anthropic_api_key_ref" in changed_keys do
      Logger.warning(
        "claude_code plugin: anthropic_api_key_ref changed but running cc sessions " <>
          "are unaffected (key is injected at spawn time). " <>
          "Restart active sessions to apply the new API key reference."
      )
    end

    # For all other config keys (http_proxy, https_proxy, no_proxy, esrd_url),
    # the effective change is visible to new sessions automatically — they call
    # Config.resolve/2 at spawn time. No rebinding of running processes required.
    :ok
  end
end

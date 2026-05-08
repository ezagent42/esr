defmodule Esr.Plugin.Behaviour do
  @moduledoc """
  Optional behaviour for plugins that support hot config reload.

  Plugins MUST implement this iff their manifest declares
  `hot_reloadable: true`. The framework checks
  `function_exported?(module, :on_config_change, 1)` at reload
  invocation time (not at boot).

  ## Callback semantics

  `on_config_change/1` is called by `Esr.Commands.Plugin.Reload` after
  `/plugin:reload <name>` is issued. `changed_keys` is the list of
  config key names whose effective value (merged across all three layers:
  workspace > user > global) differs from the value at the time the
  plugin last entered `:ok` state.

  Empty list = operator-triggered force reload (no actual config change
  was detected). The callback still fires — the plugin may use this to
  re-bind connections, flush caches, etc.

  The callback MUST read new config values via `Esr.Plugin.Config.get/3`
  (or `resolve/2`). Do NOT accept config as callback arguments — the
  three-layer store is already up-to-date when the callback fires.

  Return `:ok` if the plugin successfully applied the new config.
  The framework updates the internal config snapshot.

  Return `{:error, reason}` if the plugin failed to apply. The framework
  logs `[warning] plugin <name> failed to apply config change: <reason>`
  and does NOT update the snapshot. The plugin is responsible for its
  own fallback behavior (Q5 — no framework-level rollback).

  ## VS Code alignment

  Mirrors `vscode.workspace.onDidChangeConfiguration`:
    - Trigger-only (no old_config / new_config passed)
    - Plugin reads current state on demand
    - No framework rollback on failure
    - Empty `changed_keys` = force reload (callback still fires)

  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §2.
  """

  @type changed_keys :: [String.t()]
  @type reason :: term()

  @doc """
  Called when `/plugin:reload <name>` is invoked AND the plugin's
  manifest declares `hot_reloadable: true`.

  `changed_keys` — list of config key names whose effective value
  differs from the last-ok snapshot. Empty list = force reload.

  Return `:ok` on success (framework updates snapshot).
  Return `{:error, reason}` on failure (framework logs warning;
  snapshot NOT updated; no rollback).
  """
  @callback on_config_change(changed_keys()) :: :ok | {:error, reason()}
end

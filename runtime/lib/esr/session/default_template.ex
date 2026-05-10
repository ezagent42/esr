defmodule Esr.Session.DefaultTemplate do
  @moduledoc """
  Operator-configured default SessionTemplate.

  When `/session:new` is invoked without an explicit `template=` arg,
  this module's `current/0` resolves the template name to instantiate.

  ## Storage

  The default template name lives in plugin config under the virtual
  plugin name `"session"`, key `"default_template"`. The "session"
  plugin is virtual — there's no plugin manifest for it; the namespace
  exists purely to give operators a stable path to write the value via
  the existing `/plugin:set` slash:

      /plugin:set plugin=session key=default_template value=feishu-cc

  Reading routes through `Esr.Plugin.Config.get/3` against the standard
  per-plugin config dir (`$ESRD_HOME/<inst>/plugins/session/config.yaml`).
  No plugin process is needed; it's just a config-shaped key.

  ## Auto-election

  At boot, after `Esr.Bundle.Loader.load_all/0` populates the
  `Esr.SessionTemplate.Registry`, `auto_elect_if_single/0` writes the
  name of the lone registered template as the default — but only when
  no default has been configured yet. Idempotent: safe to call multiple
  times; no-op when a default is already set or when 0/N templates are
  registered.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §5.4. Plan Phase 5 Task 5.1.
  """

  require Logger

  @plugin_namespace "session"
  @config_key "default_template"

  @doc """
  Read the currently-configured default template name.

  Returns `{:ok, name}` when a default is set, or `:not_set` otherwise.
  """
  @spec current(keyword()) :: {:ok, String.t()} | :not_set
  def current(opts \\ []) do
    path_opts = config_path_opts(opts)

    case Esr.Plugin.Config.get(@plugin_namespace, @config_key, path_opts) do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> :not_set
    end
  end

  @doc """
  Write `name` as the default template via `Esr.Plugin.Config.store_layer/4`
  at the global layer.

  Mirrors what `/plugin:set plugin=session key=default_template value=<name>`
  does. Returns `:ok` on success or `{:error, term}` on write failure.
  """
  @spec set(String.t(), keyword()) :: :ok | {:error, term()}
  def set(name, opts \\ []) when is_binary(name) and name != "" do
    path_opts = config_path_opts(opts)
    layer_opts = [{:layer, :global} | path_opts]

    try do
      Esr.Plugin.Config.store_layer(@plugin_namespace, @config_key, name, layer_opts)
    rescue
      e -> {:error, e}
    end
  end

  @doc """
  Boot-time hook: if no default is set AND exactly one template is
  registered, write that template's name as the default.

  Idempotent. Returns `:ok` regardless of outcome (logs the action
  taken). Callers don't need to branch on the result.

    * 0 templates → no-op (caller sees `:not_set` until a template lands)
    * 1 template + no default → writes that template's name as default
    * 1 template + existing default → no-op
    * N templates + no default → no-op (operator must pick explicitly)
  """
  @spec auto_elect_if_single(keyword()) :: :ok
  def auto_elect_if_single(opts \\ []) do
    case current(opts) do
      {:ok, _existing} ->
        # Already set; never overwrite.
        :ok

      :not_set ->
        case Esr.SessionTemplate.Registry.list_all() do
          [%{name: name}] when is_binary(name) ->
            case set(name, opts) do
              :ok ->
                Logger.info(
                  "session.default_template: auto-elected '#{name}' (single registered template)"
                )

                :ok

              {:error, reason} ->
                Logger.warning(
                  "session.default_template: auto-elect of '#{name}' failed: #{inspect(reason)}"
                )

                :ok
            end

          [] ->
            :ok

          [_, _ | _] = many ->
            Logger.info(
              "session.default_template: #{length(many)} templates registered + no default; " <>
                "operator must pick via `/plugin:set plugin=session key=default_template value=<name>`"
            )

            :ok
        end
    end
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  # Build the path opts for Esr.Plugin.Config. Accepts an
  # explicit `:global_path` override (test seam) and otherwise falls
  # back to `Esr.Paths.plugin_global_dir/1` for the "session" namespace.
  defp config_path_opts(opts) do
    case Keyword.fetch(opts, :global_path) do
      {:ok, path} -> [global_path: path]
      :error -> [global_path: Esr.Paths.plugin_global_dir(@plugin_namespace)]
    end
  end
end

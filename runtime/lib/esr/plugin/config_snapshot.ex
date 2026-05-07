defmodule Esr.Plugin.ConfigSnapshot do
  @moduledoc """
  ETS-backed store for per-plugin "last-ok" config snapshots.

  A snapshot is the result of `Esr.Plugin.Config.resolve/2` at the
  moment a plugin last successfully applied its config — either at boot
  (via `Esr.Plugin.Loader.start_plugin/2`) or after a successful
  `on_config_change/1` return.

  Used by `Esr.Commands.Plugin.Reload` to compute `changed_keys`:
  the diff between the stored snapshot and the current effective config.

  ## ETS table lifecycle

  The table is created once at application start by `create_table/0`,
  called from `Esr.Application.start/2` BEFORE `load_enabled_plugins/0`.
  The table uses `:public` access so any process (slash command task,
  plugin process, test process) can read/write without routing through
  a GenServer.

  Entries survive plugin process restarts because the table is owned by
  the application process (not any plugin process).

  ## API

    * `create_table/0`       — Create the ETS table. Called once at boot.
    * `get/1`               — Retrieve snapshot; returns %{} if absent.
    * `init/2`              — Store initial snapshot (called by Loader at plugin start).
    * `update/1`            — Re-resolve and store snapshot after successful reload.
    * `update_with_path/2`  — Same as update/1 but accepts path opts (test seam).

  Spec: docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md §5.
  """

  @table :esr_plugin_config_snapshots

  @doc "Create the ETS table. Called once at application start."
  @spec create_table() :: :ok
  def create_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Retrieve the stored snapshot for `plugin_name`.
  Returns `%{}` if no snapshot exists (e.g., first call after a fresh boot).
  """
  @spec get(plugin_name :: String.t()) :: map()
  def get(plugin_name) do
    case :ets.lookup(@table, plugin_name) do
      [{^plugin_name, snapshot}] -> snapshot
      [] -> %{}
    end
  end

  @doc """
  Store `snapshot` as the baseline for `plugin_name`.
  Called by `Esr.Plugin.Loader.start_plugin/2` immediately after a plugin
  is loaded, so the first `/plugin:reload` always has a baseline to diff against.
  """
  @spec init(plugin_name :: String.t(), snapshot :: map()) :: :ok
  def init(plugin_name, snapshot) do
    :ets.insert(@table, {plugin_name, snapshot})
    :ok
  end

  @doc """
  Re-resolve the current effective config for `plugin_name` (using
  production default paths — reads global layer only) and replace the
  stored snapshot. Called after a successful `on_config_change/1` return.
  """
  @spec update(plugin_name :: String.t()) :: :ok
  def update(plugin_name) do
    update_with_path(plugin_name, [])
  end

  @doc """
  Same as `update/1` but accepts `path_opts` for the config resolver.
  Used as a test seam — tests pass `global_path:` to point at a tmp file.
  """
  @spec update_with_path(plugin_name :: String.t(), path_opts :: keyword()) :: :ok
  def update_with_path(plugin_name, path_opts) do
    current = Esr.Plugin.Config.resolve(plugin_name, path_opts)
    :ets.insert(@table, {plugin_name, current})
    :ok
  end
end

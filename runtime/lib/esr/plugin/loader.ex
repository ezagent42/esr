defmodule Esr.Plugin.Loader do
  @moduledoc """
  Discover plugins on disk, topo-sort by dependency, start each enabled
  plugin's contributions in core registries.

  Spec: `docs/superpowers/specs/2026-05-04-plugin-mechanism-design.md` §五.

  Phase-1 implementation:
    * `discover/1` walks `runtime/lib/esr/plugins/<name>/manifest.yaml`
      (or any plugin root path) and parses each manifest via
      `Esr.Plugin.Manifest`.
    * `topo_sort_enabled/2` produces a start order, rejecting cycles
      and missing dependencies.
    * `start_plugin/2` runs `Manifest.validate/1` then registers the
      plugin's declared contributions into core registries
      (Phase 1 supports python_sidecars; capabilities, slash routes,
      agents, adapters arrive when the corresponding registries grow
      `register/3`-style APIs in subsequent tasks).
    * `stop_plugin/1` is a no-op stub. Phase 2 will gain real
      teardown semantics.

  ## Default plugin root

  `Esr.Paths.plugins_dir/0` returns `runtime/lib/esr/plugins/` when the
  app is built from-source. Tests pass an explicit tmp dir.
  """

  require Logger

  alias Esr.Plugin.ConfigSnapshot
  alias Esr.Plugin.Manifest
  alias Esr.Plugin.Version, as: PluginVersion

  @default_root Path.expand("../plugins", __DIR__)

  @doc "Returns the default plugins root directory. Used by commands that need to discover plugins."
  @spec default_root() :: Path.t()
  def default_root, do: @default_root

  @typedoc "A plugin's name (kebab-case binary)."
  @type plugin_name :: String.t()

  @doc """
  Scan `root` for `<name>/manifest.yaml` files and return parsed
  manifests.

  Missing root → `{:ok, []}`. Plugin folders without a manifest file
  are skipped (operators may keep work-in-progress directories around).
  Plugin folders with a malformed manifest abort discovery.
  """
  @spec discover(Path.t()) ::
          {:ok, [{plugin_name(), Manifest.t()}]} | {:error, term()}
  def discover(root \\ @default_root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
          dir = Path.join(root, entry)
          manifest_path = Path.join(dir, "manifest.yaml")

          cond do
            not File.dir?(dir) ->
              {:cont, {:ok, acc}}

            not File.regular?(manifest_path) ->
              {:cont, {:ok, acc}}

            true ->
              case Manifest.parse(manifest_path) do
                {:ok, manifest} ->
                  {:cont, {:ok, [{manifest.name, manifest} | acc]}}

                {:error, reason} ->
                  {:halt, {:error, {:manifest_invalid, entry, reason}}}
              end
          end
        end)
        |> case do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          err -> err
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:plugin_root_unreadable, root, reason}}
    end
  end

  @doc """
  Return the start order for the subset of `discovered` plugins listed
  in `enabled_names`, honoring `depends_on.plugins` edges.

  Plugins not in `enabled_names` are skipped entirely. A plugin that
  depends on a name not in the enabled set is rejected with
  `{:missing_dep, plugin_name, dep_name}` — operators get a clear
  signal rather than a silent skip.

  Cycles surface as `{:error, :cycle}`.
  """
  @spec topo_sort_enabled(
          [{plugin_name(), Manifest.t()}],
          [plugin_name()]
        ) :: {:ok, [{plugin_name(), Manifest.t()}]} | {:error, term()}
  def topo_sort_enabled(discovered, enabled_names) when is_list(discovered) do
    by_name = Map.new(discovered)
    enabled_set = MapSet.new(enabled_names)

    enabled = for {n, m} <- discovered, MapSet.member?(enabled_set, n), do: {n, m}

    with :ok <- check_deps_present(enabled, enabled_set) do
      topo_sort(enabled, by_name)
    end
  end

  defp check_deps_present(enabled, enabled_set) do
    Enum.reduce_while(enabled, :ok, fn {name, manifest}, :ok ->
      missing =
        manifest
        |> Map.get(:depends_on, %{})
        |> Map.get(:plugins, [])
        |> Enum.find(fn dep -> not MapSet.member?(enabled_set, dep) end)

      case missing do
        nil -> {:cont, :ok}
        dep -> {:halt, {:error, {:missing_dep, name, dep}}}
      end
    end)
  end

  # Kahn's algorithm: nodes with no remaining unsatisfied deps go first.
  defp topo_sort(enabled, by_name) do
    name_to_deps =
      for {name, manifest} <- enabled, into: %{} do
        {name, MapSet.new(manifest.depends_on.plugins)}
      end

    do_topo(name_to_deps, [], by_name)
  end

  defp do_topo(remaining, ordered, by_name) when map_size(remaining) == 0 do
    {:ok, Enum.map(Enum.reverse(ordered), fn name -> {name, Map.fetch!(by_name, name)} end)}
  end

  defp do_topo(remaining, ordered, by_name) do
    ready = for {n, deps} <- remaining, MapSet.size(deps) == 0, do: n

    case ready do
      [] ->
        {:error, :cycle}

      _ ->
        # Process the alphabetically-first ready node so output is
        # deterministic regardless of map iteration order.
        next = ready |> Enum.sort() |> List.first()

        new_remaining =
          remaining
          |> Map.delete(next)
          |> Enum.into(%{}, fn {n, deps} -> {n, MapSet.delete(deps, next)} end)

        do_topo(new_remaining, [next | ordered], by_name)
    end
  end

  @doc """
  Validate `manifest` then register its declared contributions in core
  registries. Phase-1 supports `python_sidecars` + `capabilities`;
  remaining declaration types (slash_routes, agent_defs, entities,
  http_routes, …) arrive as their target registries grow
  `register/2`-style APIs in subsequent tasks.

  Returns `{:ok, :registered}` on success or `{:error, reason}` if
  validation fails.
  """
  @spec start_plugin(plugin_name(), Manifest.t()) :: {:ok, :registered} | {:error, term()}
  def start_plugin(name, %Manifest{} = manifest) do
    with :ok <- check_core_version(manifest),
         :ok <- Manifest.validate(manifest),
         :ok <- register_capabilities(name, manifest),
         :ok <- register_python_sidecars(manifest),
         :ok <- register_entities(manifest),
         :ok <- register_slash_routes(name, manifest),
         :ok <- register_startup(name, manifest),
         :ok <- register_media_types(name, manifest),
         :ok <- register_channels(name, manifest) do
      # HR-1: take a config snapshot at plugin load time so the first
      # /plugin:reload always has a baseline to diff against.
      # ConfigSnapshot.create_table/0 is guaranteed to have been called
      # by Esr.Application.start/2 before load_enabled_plugins/0.
      snapshot = Esr.Plugin.Config.resolve(name)
      ConfigSnapshot.init(name, snapshot)

      Logger.info("plugin loader: started #{name} v#{manifest.version}")
      {:ok, :registered}
    end
  end

  @doc """
  Tear down a plugin's contributions in core registries.

  Phase-4 (audit #6 / 2026-05-08-plugin-command-registration spec §5.3):
  unregister the plugin's slash-route overlay so a future hot-reload
  doesn't see stale routes from a previous version of the manifest.

  Other contribution types (capabilities, python_sidecars, entities,
  startup callbacks) don't yet have teardown wired here — they predate
  this audit and ship without `unregister/1` siblings. Adding those is
  tracked in the same plan's later phases.

  Idempotent: stopping a plugin that was never started is `:ok`.
  """
  @spec stop_plugin(plugin_name()) :: :ok
  def stop_plugin(name) when is_binary(name) do
    :ok = Esr.Resource.SlashRoute.Registry.unregister_overlay(name)
    :ok
  end

  @doc """
  PR-3.4 (2026-05-05): invoke every enabled plugin's `startup`
  callback in plugin-enable order. Called once from
  `Esr.Application.start/2` after `restore_adapters_from_disk/1`.

  No `try/rescue`. A startup callback raising propagates and crashes
  esrd boot — the user-set design philosophy (`feedback_let_it_crash_no_workarounds`)
  prefers loud failure over silent-degrade `:warning` logs.
  """
  @spec run_startup() :: :ok
  def run_startup do
    callbacks = :persistent_term.get({__MODULE__, :startup_callbacks}, [])

    Enum.each(callbacks, fn {plugin, module, function} ->
      Logger.info("plugin loader: running startup #{plugin} → #{inspect(module)}.#{function}/0")
      apply(module, function, [])
    end)

    :ok
  end

  @doc false
  # Test-only: clear the startup-callbacks store so independent tests
  # don't accumulate state across runs. Production never calls this.
  def __reset_startup_callbacks__, do: :persistent_term.erase({__MODULE__, :startup_callbacks})

  # ------------------------------------------------------------------
  # Phase-7 core version guard (Task 7.3)
  # ------------------------------------------------------------------

  defp check_core_version(%Manifest{depends_on: depends_on}) do
    constraint = depends_on[:core]

    if is_binary(constraint) and constraint != "" do
      esrd_vsn = PluginVersion.esrd_version()

      case PluginVersion.satisfies?(constraint, esrd_vsn) do
        true ->
          :ok

        false ->
          {:error, {:core_version_mismatch, constraint, esrd_vsn}}

        {:error, :invalid_constraint} ->
          {:error, {:invalid_core_constraint, constraint}}
      end
    else
      :ok
    end
  end

  # ------------------------------------------------------------------
  # Phase-1 contribution handlers
  # ------------------------------------------------------------------

  # Inject manifest-declared capability strings into the core
  # Permission.Registry under the plugin's owning module. Idempotent —
  # Permission.Registry.register/2 silently no-ops on re-registration.
  # Cap-prefix enforcement already happened in Manifest.validate/1.
  defp register_capabilities(plugin_name, %Manifest{declares: declares}) do
    caps = Map.get(declares, :capabilities, [])

    declared_by_atom =
      ("Elixir.Esr.Plugins." <> Macro.camelize(plugin_name))
      |> String.to_atom()

    Enum.each(caps, fn cap when is_binary(cap) ->
      Esr.Resource.Permission.Registry.register(cap, declared_by: declared_by_atom)
    end)

    :ok
  end

  defp register_python_sidecars(%Manifest{declares: declares}) do
    sidecars = Map.get(declares, :python_sidecars, [])

    Enum.each(sidecars, fn entry ->
      adapter_type = entry["adapter_type"] || entry[:adapter_type]
      python_module = entry["python_module"] || entry[:python_module]

      if is_binary(adapter_type) and is_binary(python_module) do
        :ok = Esr.Resource.Sidecar.Registry.register(adapter_type, python_module)
      end
    end)

    :ok
  end

  # PR-3.2: register manifest-declared `entities:` entries with
  # `kind: stateful` into `Esr.Entity.Agent.StatefulRegistry`.
  # AgentSpawner uses the registry to decide whether to spawn a
  # per-session pid for that module (vs. recording a stateless
  # `{:proxy_module, Mod}` marker). Other kinds (`proxy`, etc.) are
  # ignored by this handler today.
  defp register_entities(%Manifest{declares: declares}) do
    entities = Map.get(declares, :entities, [])

    Enum.each(entities, fn entry ->
      kind = (entry["kind"] || entry[:kind] || "") |> to_string()
      module_str = entry["module"] || entry[:module]

      if kind == "stateful" and is_binary(module_str) do
        case safe_concat(module_str) do
          {:ok, mod} -> :ok = Esr.Entity.Agent.StatefulRegistry.register(mod)
          :error -> :ok
        end
      end
    end)

    :ok
  end

  defp safe_concat(module_str) when is_binary(module_str) do
    {:ok, Module.concat([module_str])}
  rescue
    ArgumentError -> :error
  end

  # Audit #6 (2026-05-08-plugin-command-registration spec §5.3-§5.4):
  # register the manifest's `slash_routes:` block as a per-plugin overlay
  # on `Esr.Resource.SlashRoute.Registry`. Manifest-level shape +
  # namespace + permission-subset checks already ran in
  # `Manifest.validate/1`; the registry re-checks for cross-plugin
  # collision against base yaml + every other already-installed overlay.
  #
  # No-op cases (both produce `:ok` without touching the registry):
  #   * `slash_routes:` key absent entirely (`Map.get/2` returns nil)
  #   * `slash_routes: {}` parses to an empty map (the gate-only manifest
  #     style that ships first to validate the mechanism)
  #
  # The "block with both `slashes: {}` and `internal_kinds: {}`" case
  # falls through to `parse_block_to_snapshot/1`, which produces an
  # empty snapshot; `register_overlay/2` accepts it (registers an
  # overlay carrying zero entries — harmless, costs one map entry).
  defp register_slash_routes(plugin_name, %Manifest{declares: declares}) do
    case Map.get(declares, :slash_routes) do
      nil ->
        :ok

      %{} = block when block == %{} ->
        :ok

      block when is_map(block) ->
        snapshot =
          Esr.Resource.SlashRoute.Registry.FileLoader.parse_block_to_snapshot(block)

        Esr.Resource.SlashRoute.Registry.register_overlay(plugin_name, snapshot)
    end
  end

  # PR-3.4 (2026-05-05): parse the manifest's `startup:` block via
  # `Manifest.startup_callback/1` (which validates + resolves module
  # exports) and append the validated `{plugin, module, function}`
  # tuple to the `:persistent_term` callbacks store. No `try/rescue`
  # — invalid manifest crashes start_plugin/2 by design.
  defp register_startup(plugin_name, %Manifest{} = manifest) do
    case Manifest.startup_callback(manifest) do
      :none ->
        :ok

      {:ok, {module, function}} ->
        current = :persistent_term.get({__MODULE__, :startup_callbacks}, [])
        :persistent_term.put(
          {__MODULE__, :startup_callbacks},
          current ++ [{plugin_name, module, function}]
        )
        :ok

      {:error, _} = err ->
        err
    end
  end

  # D5 (2026-05-08-multimedia-content-protocol-design §4.1): register
  # the manifest's `declares.media_types` block into
  # `Esr.Resource.Media.PluginRegistry`. An absent block (non-multimedia
  # plugin) is represented as `{inbound: [], outbound: []}` by the
  # manifest parser — registering it is a no-op from the routing layer's
  # perspective (`supports?/3` returns false for any media type), but
  # it keeps the registry consistent: every loaded plugin has a row.
  defp register_media_types(plugin_name, %Manifest{declares: declares}) do
    media_types = Map.get(declares, :media_types, %{inbound: [], outbound: []})
    :ok = Esr.Resource.Media.PluginRegistry.register(plugin_name, media_types)
  end

  # 2026-05-10 SessionTemplate + Channel migration, Phase 1: each
  # `channels:` entry on the manifest is registered into
  # `Esr.Channel.Registry` under the key `<plugin>.<channel_name>`.
  # Module existence is already enforced by the manifest parser
  # (`parse_channel_entry/1` calls `Code.ensure_loaded?/1`), so we
  # don't re-validate here. An absent `channels:` block is a no-op
  # (default `[]`).
  defp register_channels(plugin_name, %Manifest{channels: channels})
       when is_list(channels) do
    Enum.each(channels, fn %{name: channel_name, module: module} ->
      :ok = Esr.Channel.Registry.register(plugin_name, channel_name, module)
    end)

    :ok
  end
end

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

  alias Esr.Plugin.Manifest

  @default_root Path.expand("../plugins", __DIR__)

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
    with :ok <- Manifest.validate(manifest),
         :ok <- register_capabilities(name, manifest),
         :ok <- register_python_sidecars(manifest),
         :ok <- register_entities(manifest),
         :ok <- register_startup(name, manifest) do
      Logger.info("plugin loader: started #{name} v#{manifest.version}")
      {:ok, :registered}
    end
  end

  @doc """
  Phase-1 stub. Phase 2 will tear down per-plugin contributions.
  """
  @spec stop_plugin(plugin_name()) :: :ok
  def stop_plugin(_name), do: :ok

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
end

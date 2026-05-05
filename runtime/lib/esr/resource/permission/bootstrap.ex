defmodule Esr.Resource.Permission.Bootstrap do
  @moduledoc """
  Populates `Esr.Resource.Permission.Registry` with the union of:

  1. Subsystem-intrinsic permissions (`cap.manage`, `cap.read`) that
     the capabilities subsystem itself implements and that operators
     need in order to author and read `capabilities.yaml`.
  2. Runtime-intrinsic MCP tool names registered via the `Esr.Handler`
     behaviour's `permissions/0` callback. Discovery uses
     `Application.spec(:esr, :modules)` filtered by
     `function_exported?(mod, :permissions, 0)`.

  Runs once at boot as a transient `Task` child of
  `Esr.Resource.Capability.Supervisor`, scheduled after
  `Esr.Resource.Permission.Registry`. Python-side handler permissions arrive
  later over the `handler_hello` IPC envelope (spec §3.1, §4.1).
  """

  @behaviour Esr.Role.Control

  alias Esr.Resource.Permission.Registry

  # Subsystem-intrinsic permissions — declared by the capabilities
  # subsystem itself, always present regardless of loaded modules.
  @subsystem_permissions [
    {"cap.manage", Esr.Resource.Capability},
    {"cap.read", Esr.Resource.Capability},
    # Track 0 Task 0.6 — `plugin/manage` gates the 5 `/plugin {list,info,
    # install,enable,disable}` admin commands. Declared by the plugin
    # subsystem itself, always present regardless of which plugins are
    # installed.
    {"plugin/manage", Esr.Plugin.Loader}
  ]

  @doc """
  Child-spec shim so `Esr.Resource.Capability.Supervisor` can list this
  module directly in its child list. Starts a short-lived `Task`
  that runs `bootstrap/1` and exits `:normal`.

  Accepts `dump_path:` — when present, the task calls
  `Esr.Resource.Permission.Registry.dump_json/1` with that path once all
  permissions have been registered. Used so `esr cap list` can read
  a JSON snapshot of the registry without a live runtime RPC.
  """
  def child_spec(opts) do
    dump_path = Keyword.get(opts, :dump_path)

    %{
      id: __MODULE__,
      start: {Task, :start_link, [fn -> bootstrap(dump_path: dump_path) end]},
      restart: :transient,
      type: :worker
    }
  end

  @doc """
  Register every subsystem-intrinsic + handler-declared permission
  into `Esr.Resource.Permission.Registry`. Idempotent — re-running is safe.
  """
  @spec bootstrap() :: :ok
  def bootstrap, do: bootstrap([])

  @doc """
  Variant of `bootstrap/0` that additionally writes a JSON snapshot
  of the registry to `opts[:dump_path]` once registration completes.
  Snapshot omitted when no path is given.
  """
  @spec bootstrap(keyword()) :: :ok
  def bootstrap(opts) when is_list(opts) do
    for {perm, mod} <- @subsystem_permissions do
      Registry.register(perm, declared_by: mod)
    end

    for mod <- handler_modules(),
        perm <- safe_permissions(mod) do
      Registry.register(perm, declared_by: mod)
    end

    # PR-4.4: dropped the boot-time JSON dump (was at
    # `~/.esrd/<env>/permissions_registry.json`). The Elixir-native
    # `esr exec /cap list` path (PR-2.6) reads the registry directly
    # via the slash dispatch — no cross-process file is needed. The
    # Python `esr cap list` consumer in py/src/esr/cli/cap.py becomes
    # stale until Phase 4 PR-4.6/4.7 ports / deletes Python CLI.
    _ = opts

    :ok
  end

  # Find every loaded :esr module that exports permissions/0.
  # Application.spec returns atoms; ensure_loaded guards against
  # modules that haven't been code-loaded yet in test envs.
  defp handler_modules do
    :esr
    |> Application.spec(:modules)
    |> Kernel.||([])
    |> Enum.filter(fn mod ->
      Code.ensure_loaded?(mod) and function_exported?(mod, :permissions, 0)
    end)
  end

  # Defensive wrapper — a buggy permissions/0 should not crash boot.
  defp safe_permissions(mod) do
    try do
      case mod.permissions() do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> []
      end
    rescue
      _ -> []
    end
  end
end

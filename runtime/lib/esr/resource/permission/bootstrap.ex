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

    case Keyword.get(opts, :dump_path) do
      nil -> :ok
      path when is_binary(path) -> safe_dump(path)
    end

    :ok
  end

  # Dump failures (e.g. permission denied, read-only volume) must not
  # crash boot — snapshot is a convenience for CLI, not a liveness
  # dependency. Log and continue.
  defp safe_dump(path) do
    try do
      Registry.dump_json(path)
    rescue
      exc ->
        require Logger
        Logger.warning(
          "permissions: dump_json failed at #{path} — #{Exception.message(exc)}; continuing"
        )
        :ok
    end
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

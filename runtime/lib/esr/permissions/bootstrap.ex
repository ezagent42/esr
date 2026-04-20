defmodule Esr.Permissions.Bootstrap do
  @moduledoc """
  Populates `Esr.Permissions.Registry` with the union of:

  1. Subsystem-intrinsic permissions (`cap.manage`, `cap.read`) that
     the capabilities subsystem itself implements and that operators
     need in order to author and read `capabilities.yaml`.
  2. Runtime-intrinsic MCP tool names registered via the `Esr.Handler`
     behaviour's `permissions/0` callback. Discovery uses
     `Application.spec(:esr, :modules)` filtered by
     `function_exported?(mod, :permissions, 0)`.

  Runs once at boot as a transient `Task` child of
  `Esr.Capabilities.Supervisor`, scheduled after
  `Esr.Permissions.Registry`. Python-side handler permissions arrive
  later over the `handler_hello` IPC envelope (spec §3.1, §4.1).
  """

  alias Esr.Permissions.Registry

  # Subsystem-intrinsic permissions — declared by the capabilities
  # subsystem itself, always present regardless of loaded modules.
  @subsystem_permissions [
    {"cap.manage", Esr.Capabilities},
    {"cap.read", Esr.Capabilities}
  ]

  @doc """
  Child-spec shim so `Esr.Capabilities.Supervisor` can list this
  module directly in its child list. Starts a short-lived `Task`
  that runs `bootstrap/0` and exits `:normal`.
  """
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [&__MODULE__.bootstrap/0]},
      restart: :transient,
      type: :worker
    }
  end

  @doc """
  Register every subsystem-intrinsic + handler-declared permission
  into `Esr.Permissions.Registry`. Idempotent — re-running is safe.
  """
  @spec bootstrap() :: :ok
  def bootstrap do
    for {perm, mod} <- @subsystem_permissions do
      Registry.register(perm, declared_by: mod)
    end

    for mod <- handler_modules(),
        perm <- safe_permissions(mod) do
      Registry.register(perm, declared_by: mod)
    end

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

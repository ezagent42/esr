defmodule Esr.Commands.Cap.List do
  @moduledoc """
  `cap_list` slash / admin-queue command — read-only enumeration of
  every declared permission, grouped by the module that declared it.

  Reads `Esr.Resource.Permission.Registry` directly (in-memory ETS).
  Replaces the Python `esr cap list` path that consumed
  `permissions_registry.json` (deleted in PR-4.4) — this Elixir-native
  implementation needs no on-disk snapshot.

  Phase B-2 of the Phase 3/4 finish (2026-05-05). See
  `docs/notes/2026-05-05-cli-dual-rail.md`.
  """

  use Esr.Commands.Meta

  command :cap_list do
    slash         :none
    category      "Capabilities"
    description   "列出所有已声明的 permission（来自内存中的 Esr.Resource.Permission.Registry）"
    permission    "cap.read"
    requires_user_binding      false
    requires_workspace_binding false
  end

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(_cmd) do
    text =
      Esr.Resource.Permission.Registry.all()
      |> Enum.sort()
      |> Enum.join("\n")

    body = if text == "", do: "no permissions registered", else: text
    {:ok, %{"text" => body}}
  end
end

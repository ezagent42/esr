defmodule Esr.Commands.Adapter.Enable do
  @moduledoc """
  `/adapter:enable name=<n>` — move `adapters/_disabled/<name>/` →
  `adapters/<name>/`. Inverse of `/adapter:disable`.

  Carries no secrets — exposes both slash + CLI per yaml-layout-v2
  spec § 4.6 slash-discipline. Operator-facing.

  After re-enabling, calls `Esr.Application.restore_adapters_from_disk/1`
  + `Esr.Plugin.Loader.run_startup/0` so the sidecar + FAA peer come
  up immediately (mirrors `/adapter:refresh` semantics for this row
  only).
  """

  use Esr.Commands.Meta

  command :adapter_enable do
    slash         "/adapter:enable"
    category      "Adapters"
    description   "恢复 adapter 实例（从 adapters/_disabled/ 移回 adapters/）+ refresh"
    permission    "adapter.manage"
    requires_user_binding      false
    requires_workspace_binding false

    arg :name, required: true, doc: "adapter instance name"

    error :invalid_args,     "adapter:enable requires args.name"
    error :not_disabled,     "adapter %{name} is not in adapters/_disabled/"
    error :already_enabled,  "adapter %{name} is already enabled"
    error :enable_failed,    "%{detail}"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"name" => name}}) when is_binary(name) and name != "" do
    case Esr.Adapters.enable(name) do
      :ok ->
        # Restore + run plugin startup so the row spawns immediately.
        # Mirrors `/adapter:refresh` semantics scoped to this rename.
        _ = Esr.Application.restore_adapters_from_disk(Esr.Paths.esrd_home())
        :ok = Esr.Plugin.Loader.run_startup()

        {:ok, %{"text" => "enabled adapter #{name} (moved out of adapters/_disabled/)"}}

      {:error, :not_disabled} ->
        Render.error(__MODULE__.command_meta(), :not_disabled, %{name: name})

      {:error, :already_enabled} ->
        Render.error(__MODULE__.command_meta(), :already_enabled, %{name: name})

      {:error, reason} ->
        Render.error(__MODULE__.command_meta(), :enable_failed, %{detail: inspect(reason)})
    end
  end

  def execute(_),
    do: Render.error(__MODULE__.command_meta(), :invalid_args)
end

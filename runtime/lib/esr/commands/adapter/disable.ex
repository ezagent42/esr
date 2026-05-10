defmodule Esr.Commands.Adapter.Disable do
  @moduledoc """
  `/adapter:disable name=<n>` — move `adapters/<name>/` →
  `adapters/_disabled/<name>/`. The runtime ignores anything under
  `_disabled/` on next boot (see `Esr.Adapters.list/1`).

  Carries no secrets — exposes both slash + CLI per yaml-layout-v2
  spec § 4.6 slash-discipline. Operator-facing.

  Idempotency: if the instance is already on the disabled side,
  returns `:already_disabled`. If neither side has it, returns
  `:not_found`.
  """

  use Esr.Commands.Meta

  command :adapter_disable do
    slash         "/adapter:disable"
    category      "Adapters"
    description   "暂停 adapter 实例（移到 adapters/_disabled/）— 不会删配置；可用 /adapter:enable 恢复"
    permission    "adapter.manage"
    requires_user_binding      false
    requires_workspace_binding false

    arg :name, required: true, doc: "adapter instance name"

    error :invalid_args,      "adapter:disable requires args.name"
    error :not_found,         "no adapter %{name}"
    error :already_disabled,  "adapter %{name} is already disabled"
    error :disable_failed,    "%{detail}"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"name" => name}}) when is_binary(name) and name != "" do
    case Esr.Adapters.disable(name) do
      :ok ->
        # Best-effort: terminate the running sidecar + FAA peer so the
        # runtime view matches the on-disk view immediately. On next
        # boot the disabled row is invisible to `Esr.Adapters.list/1`,
        # so this is purely a hot-stop convenience.
        case Esr.Adapters.list_disabled() |> Enum.find(&(&1.name == name)) do
          %{type: type} ->
            _ = Esr.WorkerSupervisor.terminate_adapter(type, name)

            if type == "feishu" do
              _ = Esr.Session.Admin.terminate_feishu_app_adapter(name)
            end

          _ ->
            :ok
        end

        {:ok, %{"text" => "disabled adapter #{name} (moved to adapters/_disabled/#{name}/)"}}

      {:error, :not_found} ->
        Render.error(__MODULE__.command_meta(), :not_found, %{name: name})

      {:error, :already_disabled} ->
        Render.error(__MODULE__.command_meta(), :already_disabled, %{name: name})

      {:error, reason} ->
        Render.error(__MODULE__.command_meta(), :disable_failed, %{detail: inspect(reason)})
    end
  end

  def execute(_),
    do: Render.error(__MODULE__.command_meta(), :invalid_args)
end

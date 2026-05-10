defmodule Esr.Commands.Adapter.Remove do
  @moduledoc """
  `adapter_remove` slash / admin-queue command — terminate a registered
  adapter instance. Three steps:

  1. Terminate the Python sidecar (`Esr.WorkerSupervisor.terminate_adapter/2`).
  2. Terminate the Elixir FAA peer if `type: feishu`
     (`Esr.Session.Admin.terminate_feishu_app_adapter/1`).
  3. Remove the entry directory via `Esr.Adapters.remove/1` so a future
     esrd boot doesn't respawn it.

  Migrated from `EsrWeb.CliChannel.dispatch("cli:adapters/remove", ...)`.
  Yaml-layout-v2 (spec § 4.6): inline yaml read/write replaced with
  `Esr.Adapters.{get,remove}/1`.
  """

  use Esr.Commands.Meta

  command :adapter_remove do
    slash         "/adapter:remove"
    category      "Adapters"
    description   "终止 adapter 实例（sidecar + FAA peer）并从 adapters/<name>/ 移除"
    permission    "adapter.manage"
    requires_user_binding      false
    requires_workspace_binding false

    arg :instance_id, required: true, doc: "adapter 实例 id"

    error :invalid_args,     "adapter_remove requires args.instance_id"
    error :unknown_instance, "no adapter %{instance_id}"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"instance_id" => instance_id}})
      when is_binary(instance_id) and instance_id != "" do
    case Esr.Adapters.get(instance_id) do
      {:ok, %{type: type}} ->
        _ = Esr.WorkerSupervisor.terminate_adapter(type, instance_id)

        if type == "feishu" do
          _ = Esr.Session.Admin.terminate_feishu_app_adapter(instance_id)
        end

        :ok = Esr.Adapters.remove(instance_id)

        {:ok, %{"text" => "removed #{type} adapter instance_id=#{instance_id}"}}

      {:error, :not_found} ->
        Render.error(__MODULE__.command_meta(), :unknown_instance, %{instance_id: instance_id})
    end
  end

  def execute(_),
    do: Render.error(__MODULE__.command_meta(), :invalid_args)
end

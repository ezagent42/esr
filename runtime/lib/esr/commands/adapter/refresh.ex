defmodule Esr.Commands.Adapter.Refresh do
  @moduledoc """
  `adapter_refresh` slash / admin-queue command — re-run the boot-time
  adapters bootstrap without an esrd restart. Two steps:

  1. `Esr.Application.restore_adapters_from_disk/1` — re-spawn Python
     sidecars per `adapters.yaml`.
  2. `Esr.Plugin.Loader.run_startup/0` — re-run every enabled plugin's
     startup hook (today: feishu's `Esr.Plugins.Feishu.Bootstrap.bootstrap/0`
     which spawns one FAA peer per `type: feishu` row).

  Both calls are idempotent. Used by operators after `esr adapter add`
  to bring up both halves of a feishu instance without restart.

  Migrated from `EsrWeb.CliChannel.dispatch("cli:adapters/refresh", ...)`.
  """

  use Esr.Commands.Meta

  command :adapter_refresh do
    slash         :none
    category      "Adapters"
    description   "重新跑一次 adapters 启动流程：restore_adapters_from_disk + plugin startup hooks（不重启 esrd）"
    permission    "adapter.manage"
    requires_user_binding      false
    requires_workspace_binding false
  end

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(_cmd) do
    _ = Esr.Application.restore_adapters_from_disk(Esr.Paths.esrd_home())
    :ok = Esr.Plugin.Loader.run_startup()

    {:ok, %{"text" => "refresh ok: re-restored adapters + ran plugin startup hooks"}}
  end
end

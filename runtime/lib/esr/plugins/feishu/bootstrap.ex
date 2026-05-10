defmodule Esr.Plugins.Feishu.Bootstrap do
  @moduledoc """
  Spawns one `Esr.Entity.FeishuAppAdapter` peer per `type: feishu`
  instance returned by `Esr.Adapters.list/1` (yaml-layout-v2 spec
  § 4.5 — was `adapters.yaml` walk pre-v2).

  Two callers:

  - `Esr.Plugin.Loader.run_startup/0` — invoked at boot once
    `restore_adapters_from_disk/1` has loaded the yaml-on-disk state.
  - `Esr.Commands.Adapter.{Refresh,Rename}` slash commands —
    operator-triggered re-bootstrap after the operator mutates the
    `adapters/<name>/` directory. (Both call
    `Esr.Plugin.Loader.run_startup/0` rather than this module
    directly, but this hook is what the loader invokes.)

  Each peer registers in `Esr.Session.Admin.Process` under
  `:feishu_app_adapter_<instance_id>` (the directory basename —
  matching the Phoenix topic suffix `adapter:feishu/<instance_id>`
  the Python `adapter_runner` joins) so that
  `EsrWeb.AdapterChannel.forward_to_new_chain/2` can route inbound
  frames. Peer state additionally carries the Feishu-platform `app_id`
  from `config.app_id` (used for outbound Lark REST calls and
  `workspaces.yaml` `chats[].app_id` matching).

  Idempotent: re-spawning an already-running instance is a no-op
  (DynamicSupervisor returns `{:error, {:already_started, _pid}}`,
  swallowed). Non-feishu adapter rows are skipped.

  PR-3.4 (2026-05-05): per the plugin-startup-hook spec at
  `docs/superpowers/specs/2026-05-05-pr-3-4-feishu-startup-hook.md`.
  """

  require Logger

  @doc """
  Spawn FAA peers for every `type: feishu` row visible in the default
  esrd home (`Esr.Adapters.list/0`).
  """
  @spec bootstrap() :: :ok
  def bootstrap, do: bootstrap([])

  @doc """
  Variant taking opts — used by tests. `:home` overrides the esrd home
  for `Esr.Adapters.list/1`. Empty list (no adapters declared) is a
  no-op so `Esr.Application.start/2` boot stays clean on fresh
  installs.
  """
  @spec bootstrap(keyword()) :: :ok
  def bootstrap(opts) when is_list(opts) do
    sup = Esr.Session.Admin.children_supervisor_name()

    for %{name: instance_id, type: "feishu", config: config} <- Esr.Adapters.list(opts) do
      app_id = config["app_id"] || instance_id
      spawn_feishu_app_adapter(sup, instance_id, app_id)
    end

    :ok
  end

  defp spawn_feishu_app_adapter(sup, instance_id, app_id) do
    args = %{
      instance_id: instance_id,
      app_id: app_id,
      proxy_ctx: %{}
    }

    case DynamicSupervisor.start_child(sup, {Esr.Entity.FeishuAppAdapter, args}) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "feishu plugin: feishu_app_adapter spawn failed " <>
            "instance_id=#{inspect(instance_id)} reason=#{inspect(reason)}"
        )

        :ok
    end
  end
end

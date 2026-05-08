defmodule Esr.Plugins.Feishu.Bootstrap do
  @moduledoc """
  Spawns one `Esr.Entity.FeishuAppAdapter` peer per `type: feishu`
  instance declared in `adapters.yaml`.

  Two callers:

  - `Esr.Plugin.Loader.run_startup/0` — invoked at boot once
    `restore_adapters_from_disk/1` has loaded the yaml-on-disk state.
  - `Esr.Commands.Adapter.{Refresh,Rename}` slash commands —
    operator-triggered re-bootstrap after `esr adapter add` /
    `esr adapter rename` mutates `adapters.yaml`. (Both call
    `Esr.Plugin.Loader.run_startup/0` rather than this module
    directly, but this hook is what the loader invokes.)

  Each peer registers in `Esr.Scope.Admin.Process` under
  `:feishu_app_adapter_<instance_id>` (the YAML key — matching the
  Phoenix topic suffix `adapter:feishu/<instance_id>` the Python
  `adapter_runner` joins) so that
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
  Spawn FAA peers for every `type: feishu` row in the default
  `adapters.yaml` path.
  """
  @spec bootstrap() :: :ok
  def bootstrap, do: bootstrap(Esr.Paths.adapters_yaml())

  @doc """
  Variant taking an explicit `adapters.yaml` path — used by tests.
  Missing file is a no-op (matches the pre-PR-3.4 semantics so
  `Esr.Application.start/2` boot stays clean on a fresh install).
  """
  @spec bootstrap(Path.t()) :: :ok
  def bootstrap(adapters_yaml_path) do
    sup = Esr.Scope.Admin.children_supervisor_name()

    if File.exists?(adapters_yaml_path) do
      with {:ok, parsed} <- YamlElixir.read_from_file(adapters_yaml_path),
           instances when is_map(instances) <- parsed["instances"] || %{} do
        for {instance_id, row} <- instances,
            row["type"] == "feishu" do
          config = row["config"] || %{}
          app_id = config["app_id"] || instance_id
          spawn_feishu_app_adapter(sup, instance_id, app_id)
        end
      else
        _ -> :ok
      end
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

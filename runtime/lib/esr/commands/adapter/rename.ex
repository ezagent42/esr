defmodule Esr.Commands.Adapter.Rename do
  @moduledoc """
  `adapter_rename` slash / admin-queue command — rename an adapter
  instance from `old_instance_id` to `new_instance_id`. Same blast
  radius as remove + add: terminate old peer + sidecar, move the
  per-instance directory, refresh to spawn under new name.

  New name validated server-side via `Esr.Adapters.rename/2` (the
  same `^[A-Za-z][A-Za-z0-9_-]{0,62}$` pattern, plus reserved-prefix
  `_` rejection).

  Migrated from `EsrWeb.CliChannel.dispatch("cli:adapters/rename", ...)`.
  Yaml-layout-v2 (spec § 4.6): inline yaml r/w replaced with
  `Esr.Adapters.{get,rename}/2`.
  """

  use Esr.Commands.Meta

  command :adapter_rename do
    slash         "/adapter:rename"
    category      "Adapters"
    description   "重命名 adapter 实例（terminate old + 移动 adapters/<name>/ + refresh）"
    permission    "adapter.manage"
    requires_user_binding      false
    requires_workspace_binding false

    arg :old_instance_id, required: true, doc: "原 instance id"
    arg :new_instance_id, required: true, doc: "新 instance id（^[A-Za-z][A-Za-z0-9_-]{0,62}$）"

    error :invalid_args,            "adapter_rename requires args.old_instance_id and args.new_instance_id"
    error :invalid_new_name,        "name %{new} fails the adapter-name pattern (no leading `_`, ^[A-Za-z][A-Za-z0-9_-]{0,62}$)"
    error :old_and_new_match,       "old and new must differ"
    error :new_name_already_exists, "instance %{new} already exists"
    error :unknown_instance,        "no adapter %{old}"
    error :rename_failed,           "%{detail}"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"old_instance_id" => old, "new_instance_id" => new}})
      when is_binary(old) and old != "" and is_binary(new) and new != "" do
    cond do
      old == new ->
        Render.error(__MODULE__.command_meta(), :old_and_new_match)

      true ->
        do_rename(old, new)
    end
  end

  def execute(_),
    do: Render.error(__MODULE__.command_meta(), :invalid_args)

  defp do_rename(old, new) do
    case Esr.Adapters.get(old) do
      {:ok, %{type: type}} ->
        # 1. Terminate old running children.
        _ = Esr.WorkerSupervisor.terminate_adapter(type, old)

        if type == "feishu" do
          _ = Esr.Session.Admin.terminate_feishu_app_adapter(old)
        end

        # 2. Move the per-instance directory atomically (POSIX rename(2)).
        case Esr.Adapters.rename(old, new) do
          :ok ->
            # 3. Refresh: re-restore + run plugin startup to spawn under
            # the new name. Same flow as Esr.Commands.Adapter.Refresh.
            _ = Esr.Application.restore_adapters_from_disk(Esr.Paths.esrd_home())
            :ok = Esr.Plugin.Loader.run_startup()

            {:ok, %{"text" => "renamed #{type} adapter #{old} → #{new}"}}

          {:error, :invalid_name} ->
            Render.error(__MODULE__.command_meta(), :invalid_new_name, %{new: new})

          {:error, :already_exists} ->
            Render.error(__MODULE__.command_meta(), :new_name_already_exists, %{new: new})

          {:error, reason} ->
            Render.error(__MODULE__.command_meta(), :rename_failed, %{detail: inspect(reason)})
        end

      {:error, :not_found} ->
        Render.error(__MODULE__.command_meta(), :unknown_instance, %{old: old})
    end
  end
end

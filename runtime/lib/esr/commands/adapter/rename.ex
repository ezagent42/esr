defmodule Esr.Commands.Adapter.Rename do
  @moduledoc """
  `adapter_rename` slash / admin-queue command — rename an adapter
  instance from `old_instance_id` to `new_instance_id`. Same blast
  radius as remove + add: terminate old peer + sidecar, rewrite
  adapters.yaml with new key, refresh to spawn under new name.

  New name validated server-side
  (`^[A-Za-z][A-Za-z0-9_-]{0,62}$`) so a misconfigured caller can't
  smuggle bad bytes into the runtime.

  Migrated from `EsrWeb.CliChannel.dispatch("cli:adapters/rename", ...)`.
  """

  use Esr.Commands.Meta

  command :adapter_rename do
    slash         :none
    category      "Adapters"
    description   "重命名 adapter 实例（terminate old + 改 adapters.yaml + refresh）"
    permission    "adapter.manage"
    requires_user_binding      false
    requires_workspace_binding false

    arg :old_instance_id, required: true, doc: "原 instance id"
    arg :new_instance_id, required: true, doc: "新 instance id（^[A-Za-z][A-Za-z0-9_-]{0,62}$）"

    error :invalid_args,            "adapter_rename requires args.old_instance_id and args.new_instance_id"
    error :invalid_new_name,        "name %{new} fails %{pattern}"
    error :old_and_new_match,       "old and new must differ"
    error :new_name_already_exists, "instance %{new} already exists"
    error :unknown_instance,        "no adapter %{old}"
    error :yaml_read_failed,        "%{detail}"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render

  @name_pattern ~r/^[A-Za-z][A-Za-z0-9_-]{0,62}$/

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"old_instance_id" => old, "new_instance_id" => new}})
      when is_binary(old) and old != "" and is_binary(new) and new != "" do
    cond do
      not Regex.match?(@name_pattern, new) ->
        Render.error(__MODULE__.command_meta(), :invalid_new_name, %{
          new: new,
          pattern: Regex.source(@name_pattern)
        })

      old == new ->
        Render.error(__MODULE__.command_meta(), :old_and_new_match)

      true ->
        do_rename(old, new)
    end
  end

  def execute(_),
    do: Render.error(__MODULE__.command_meta(), :invalid_args)

  defp do_rename(old, new) do
    path = Esr.Paths.adapters_yaml()

    case read_adapters_yaml(path, old) do
      {:ok, doc, instance} ->
        instances = doc["instances"] || %{}

        if Map.has_key?(instances, new) do
          Render.error(__MODULE__.command_meta(), :new_name_already_exists, %{new: new})
        else
          type = instance["type"] || "unknown"

          # 1. Terminate old running children.
          _ = Esr.WorkerSupervisor.terminate_adapter(type, old)

          if type == "feishu" do
            _ = Esr.Session.Admin.terminate_feishu_app_adapter(old)
          end

          # 2. Rewrite adapters.yaml with new key.
          new_instances =
            instances
            |> Map.delete(old)
            |> Map.put(new, instance)

          new_doc = Map.put(doc, "instances", new_instances)
          :ok = Esr.Yaml.Writer.write(path, new_doc)

          # 3. Refresh: re-restore + run plugin startup to spawn under the
          # new name. Same flow as Esr.Commands.Adapter.Refresh.
          _ = Esr.Application.restore_adapters_from_disk(Esr.Paths.esrd_home())
          :ok = Esr.Plugin.Loader.run_startup()

          {:ok,
           %{"text" => "renamed #{type} adapter #{old} → #{new}"}}
        end

      {:error, :not_found} ->
        Render.error(__MODULE__.command_meta(), :unknown_instance, %{old: old})

      {:error, reason} ->
        Render.error(__MODULE__.command_meta(), :yaml_read_failed, %{detail: inspect(reason)})
    end
  end

  defp read_adapters_yaml(path, instance_id) do
    cond do
      not File.exists?(path) ->
        {:error, :not_found}

      true ->
        case YamlElixir.read_from_file(path) do
          {:ok, doc} when is_map(doc) ->
            instances = doc["instances"] || %{}

            case Map.get(instances, instance_id) do
              nil -> {:error, :not_found}
              instance when is_map(instance) -> {:ok, doc, instance}
            end

          {:ok, _} ->
            {:error, :malformed_yaml}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end

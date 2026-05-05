defmodule Esr.Commands.Adapter.Remove do
  @moduledoc """
  `adapter_remove` slash / admin-queue command — terminate a registered
  adapter instance. Three steps:

  1. Terminate the Python sidecar (`Esr.WorkerSupervisor.terminate_adapter/2`).
  2. Terminate the Elixir FAA peer if `type: feishu`
     (`Esr.Scope.Admin.terminate_feishu_app_adapter/1`).
  3. Remove the entry from `adapters.yaml` so a future esrd boot
     doesn't respawn it.

  Migrated from `EsrWeb.CliChannel.dispatch("cli:adapters/remove", ...)`.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"instance_id" => instance_id}})
      when is_binary(instance_id) and instance_id != "" do
    path = Esr.Paths.adapters_yaml()

    case read_adapters_yaml(path, instance_id) do
      {:ok, doc, instance} ->
        type = instance["type"] || "unknown"

        _ = Esr.WorkerSupervisor.terminate_adapter(type, instance_id)

        if type == "feishu" do
          _ = Esr.Scope.Admin.terminate_feishu_app_adapter(instance_id)
        end

        new_doc = update_in(doc, ["instances"], &Map.delete(&1 || %{}, instance_id))
        :ok = Esr.Yaml.Writer.write(path, new_doc)

        {:ok,
         %{"text" => "removed #{type} adapter instance_id=#{instance_id}"}}

      {:error, :not_found} ->
        {:error,
         %{"type" => "unknown_instance", "message" => "no adapter #{instance_id}"}}

      {:error, reason} ->
        {:error,
         %{"type" => "yaml_read_failed", "message" => inspect(reason)}}
    end
  end

  def execute(_),
    do:
      {:error,
       %{"type" => "invalid_args", "message" => "adapter_remove requires args.instance_id"}}

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

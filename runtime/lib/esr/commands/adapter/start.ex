defmodule Esr.Commands.Adapter.Start do
  @moduledoc """
  `adapter_start` slash / admin-queue command — spawn a Python adapter
  sidecar of the given type for the given instance_id. Writes nothing
  to adapters.yaml; for persistent registration use `register_adapter`
  (the existing `cli:adapters/refresh`-equivalent path) instead.

  ## Args contract — **breaking change vs. `cli:adapter/start/<type>`**

  Legacy WS topic took:

      %{"instance_id" => "X", "config" => %{"app_id" => "Y", ...}}

  i.e. `config:` was a nested map. This slash command takes flat args
  per the migration convention (`docs/notes/2026-05-05-cli-channel-migration.md`):

      args: %{
        "type" => "feishu",
        "instance_id" => "ESR开发助手",
        "app_id" => "cli_xxx",          # was config.app_id
        "app_secret" => "...",           # was config.app_secret
        "base_url" => "https://..."     # was config.base_url
      }

  Internally `Map.drop(args, ["type", "instance_id"])` produces the
  same shape `WorkerSupervisor.ensure_adapter/4` consumed via the
  legacy `payload["config"]` path, so adapter sidecars see no
  difference. Callers porting from the old topic must flatten their
  config map.

  Migrated from `EsrWeb.CliChannel.dispatch("cli:adapter/start/<type>", ...)`.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"type" => adapter_type, "instance_id" => instance_id} = args})
      when is_binary(adapter_type) and adapter_type != "" and is_binary(instance_id) and
             instance_id != "" do
    config = Map.drop(args, ["type", "instance_id"])

    url =
      "ws://127.0.0.1:" <>
        Integer.to_string(phoenix_port()) <>
        "/adapter_hub/socket/websocket?vsn=2.0.0"

    case Esr.WorkerSupervisor.ensure_adapter(adapter_type, instance_id, config, url) do
      :ok ->
        {:ok, %{"text" => "spawned #{adapter_type} adapter instance_id=#{instance_id}"}}

      :already_running ->
        {:ok, %{"text" => "#{adapter_type} adapter instance_id=#{instance_id} already running"}}

      {:error, reason} ->
        {:error,
         %{"type" => "spawn_failed", "message" => "ensure_adapter failed: #{inspect(reason)}"}}
    end
  end

  def execute(_),
    do:
      {:error,
       %{
         "type" => "invalid_args",
         "message" => "adapter_start requires args.type and args.instance_id"
       }}

  defp phoenix_port do
    case EsrWeb.Endpoint.config(:http) do
      opts when is_list(opts) -> Keyword.get(opts, :port, 4001)
      _ -> 4001
    end
  end
end

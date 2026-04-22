defmodule Esr.Admin.Commands.Notify do
  @moduledoc """
  `Esr.Admin.Commands.Notify` — emits a Feishu `reply` directive on
  behalf of the admin dispatcher (spec §6.4 Notify bullet).

  Called by `Esr.Admin.Dispatcher` inside a `Task.start` when a
  `notify`-kind command reaches the front of the queue. Pure function
  module (no GenServer) so it can be spawned and discarded.

  Routing: uses the existing `Esr.AdapterHub.Registry` — which maps
  adapter Phoenix topics (shape `"adapter:<name>/<actor_id>"`) to their
  owning actor_id — to find the first running Feishu adapter topic.
  The pattern mirrors `peer_server.ex:640-646` where tool-originated
  directives are routed to adapters: scan the registry for a topic
  matching a prefix, then broadcast on it.

  The broadcast goes on `EsrWeb.PubSub` (the single Phoenix.PubSub
  started in `Esr.Application`). The design doc references this as
  `Esr.PubSub` but the concrete registered name in the runtime is
  `EsrWeb.PubSub` (see `application.ex:24`).

  Result shape:
    * `{:ok, %{"delivered_at" => <iso8601>}}` on successful broadcast.
    * `{:error, %{"type" => "no_feishu_adapter"}}` when the registry
      has no `adapter:feishu/...` binding — callers surface this as a
      failed command without retry (operator action required).
  """

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"to" => to_open_id, "text" => text}} = _cmd)
      when is_binary(to_open_id) and is_binary(text) do
    case find_feishu_topic() do
      {:ok, topic} ->
        directive = %{
          "kind" => "reply",
          "args" => %{
            "receive_id" => to_open_id,
            "receive_id_type" => "open_id",
            "text" => text
          }
        }

        :ok = Phoenix.PubSub.broadcast(EsrWeb.PubSub, topic, {:directive, directive})

        {:ok, %{"delivered_at" => DateTime.utc_now() |> DateTime.to_iso8601()}}

      :error ->
        {:error, %{"type" => "no_feishu_adapter"}}
    end
  end

  def execute(_cmd) do
    {:error, %{"type" => "invalid_args", "message" => "notify requires args.to and args.text"}}
  end

  # Find the first `adapter:feishu/...` topic in `AdapterHub.Registry.list/0`.
  # The registry entry shape is `{topic, actor_id}` — we ignore the
  # actor_id here because the broadcast targets the topic directly.
  @spec find_feishu_topic() :: {:ok, String.t()} | :error
  defp find_feishu_topic do
    Esr.AdapterHub.Registry.list()
    |> Enum.find_value(:error, fn {topic, _actor_id} ->
      if String.starts_with?(topic, "adapter:feishu/"), do: {:ok, topic}, else: nil
    end)
  end
end

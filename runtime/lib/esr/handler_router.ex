defmodule Esr.HandlerRouter do
  @moduledoc """
  Dispatches ``handler_call`` envelopes to Python worker processes
  over Phoenix channels and awaits the matching ``handler_reply``
  (PRD 01 F11, spec §7.2).

  v0.1 scope: single worker per handler module (worker_id
  ``"default"``). The full pool (F10) adds round-robin across N
  workers per module without changing this call/0 contract.

  Flow:
   1. Subscribe the caller to ``handler_reply:<id>`` on EsrWeb.PubSub.
   2. Broadcast ``handler_call`` on ``handler:<module>/<worker_id>`` —
      the worker's joined channel receives and processes.
   3. Wait for ``{:handler_reply, envelope}`` on the PubSub topic or
      time out (default 5 s — spec §7.3).
   4. Shape the reply into
      ``{:ok, new_state, actions} | {:error, :handler_timeout}
       | {:error, {:handler_error, detail}}``.
  """

  @behaviour Esr.Role.Pipeline

  @default_timeout_ms 5_000

  @typep reply ::
           {:ok, map(), [map()]}
           | {:error, :handler_timeout}
           | {:error, {:handler_error, map()}}

  @spec call(String.t(), map(), pos_integer()) :: reply
  def call(handler_module, payload, timeout \\ @default_timeout_ms)
      when is_binary(handler_module) and is_map(payload) and is_integer(timeout) do
    id = "hc-" <> Integer.to_string(System.unique_integer([:positive]))
    reply_topic = "handler_reply:" <> id
    channel_topic = "handler:" <> handler_module <> "/default"

    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, reply_topic)

    envelope = %{
      "kind" => "handler_call",
      "id" => id,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "type" => "handler_call",
      "source" => "esr://localhost/runtime",
      "payload" => payload
    }

    # Broadcast under the unified "envelope" event shape Python's
    # handler_worker._on_frame filters on (event="envelope",
    # payload.kind="handler_call"). The envelope carries its own kind
    # for dispatch — matching the Instantiator / PeerServer convention.
    EsrWeb.Endpoint.broadcast(channel_topic, "envelope", envelope)

    try do
      receive do
        {:handler_reply, %{"id" => ^id} = reply} ->
          shape_reply(reply["payload"] || %{})
      after
        timeout -> {:error, :handler_timeout}
      end
    after
      Phoenix.PubSub.unsubscribe(EsrWeb.PubSub, reply_topic)
    end
  end

  defp shape_reply(%{"error" => err}) when is_map(err) do
    {:error, {:handler_error, err}}
  end

  defp shape_reply(%{"new_state" => new_state} = payload) do
    {:ok, new_state, Map.get(payload, "actions", [])}
  end

  defp shape_reply(other) do
    {:error, {:handler_error, %{"type" => "InvalidReply", "payload" => other}}}
  end
end

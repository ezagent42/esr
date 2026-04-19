defmodule Esr.HandlerRouter.CallTest do
  @moduledoc """
  PRD 01 F11 — HandlerRouter.call dispatches a handler_call envelope
  to a worker's Phoenix channel and awaits the matching handler_reply.
  """

  use ExUnit.Case, async: false

  alias Esr.HandlerRouter

  @module "noop"
  @worker_id "default"
  @channel_topic "handler:" <> @module <> "/" <> @worker_id

  defp simulate_reply(envelope_id, payload) do
    Phoenix.PubSub.broadcast(
      EsrWeb.PubSub,
      "handler_reply:" <> envelope_id,
      {:handler_reply, %{"id" => envelope_id, "payload" => payload}}
    )
  end

  setup do
    # Subscribe the test process directly to the outbound channel topic
    # so we can see the handler_call broadcast without running a real
    # worker. Phoenix.Channel.Server broadcasts using PubSub under the hood.
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, @channel_topic)
    :ok
  end

  test "happy call: handler_reply returns {:ok, new_state, actions}" do
    task =
      Task.async(fn ->
        HandlerRouter.call(@module, %{"state" => %{}, "event" => %{}}, 2_000)
      end)

    # Capture the outbound call and reply with a synthetic handler_reply.
    # The broadcast uses event="envelope" with kind="handler_call" inside
    # the payload — the unified wire shape Python's handler_worker filter
    # expects. Previously HandlerRouter broadcast as event="handler_call"
    # (legacy), and Python would silently drop every real handler_call.
    assert_receive %Phoenix.Socket.Broadcast{event: "envelope", payload: env}, 500
    assert env["kind"] == "handler_call"
    assert env["type"] == "handler_call"
    assert env["payload"]["state"] == %{}

    simulate_reply(env["id"], %{"new_state" => %{"c" => 1}, "actions" => []})

    assert {:ok, %{"c" => 1}, []} = Task.await(task)
  end

  test "timeout: returns {:error, :handler_timeout}" do
    assert {:error, :handler_timeout} =
             HandlerRouter.call(@module, %{"state" => %{}, "event" => %{}}, 50)
  end

  test "reply with error payload returns {:error, {:handler_error, _}}" do
    task =
      Task.async(fn ->
        HandlerRouter.call(@module, %{"state" => %{}, "event" => %{}}, 2_000)
      end)

    assert_receive %Phoenix.Socket.Broadcast{event: "envelope", payload: env}, 500
    simulate_reply(env["id"], %{"error" => %{"type" => "Boom", "message" => "bad"}})

    assert {:error, {:handler_error, %{"type" => "Boom"}}} = Task.await(task)
  end
end

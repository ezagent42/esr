defmodule Esr.EntityServerEventHandlingTest do
  @moduledoc """
  PRD 01 F06 — Entity.Server.handle_info({:inbound_event, envelope}, state)
  dedups by idempotency_key, invokes HandlerRouter.call, persists the
  returned new_state.
  """

  use ExUnit.Case, async: false

  alias Esr.Entity
  alias Esr.TestSupport.AuthContext

  # Simulates a Python handler worker by subscribing to the handler
  # channel's PubSub topic and broadcasting a reply for every inbound
  # handler_call.
  defp start_fake_worker(handler_module, reply_shaper) do
    topic = "handler:" <> handler_module <> "/default"
    test_pid = self()

    Task.async(fn ->
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, topic)
      send(test_pid, :worker_ready)
      fake_worker_loop(reply_shaper)
    end)
  end

  defp fake_worker_loop(reply_shaper) do
    receive do
      %Phoenix.Socket.Broadcast{event: "envelope", payload: env} ->
        payload = reply_shaper.(env["payload"])

        Phoenix.PubSub.broadcast(
          EsrWeb.PubSub,
          "handler_reply:" <> env["id"],
          {:handler_reply, %{"id" => env["id"], "payload" => payload}}
        )

        fake_worker_loop(reply_shaper)

      :stop ->
        :ok
    after
      5_000 -> :timeout
    end
  end

  setup do
    # CAP-4 Lane B: every inbound_event needs a grant.
    AuthContext.load_admin("test_admin")

    actor_id = "test-peer-#{System.unique_integer([:positive])}"
    {:ok, peer} =
      start_supervised(
        {Entity.Server,
         [
           actor_id: actor_id,
           actor_type: "test_actor",
           handler_module: "noop",
           initial_state: %{"counter" => 0},
           handler_timeout: 200
         ]}
      )

    %{peer: peer, actor_id: actor_id}
  end

  test "inbound event triggers HandlerRouter.call and persists new_state",
       %{actor_id: actor_id} do
    # Fake worker responds by incrementing "counter"
    worker =
      start_fake_worker("noop", fn payload ->
        state = payload["state"] || %{}
        new_counter = Map.get(state, "counter", 0) + 1
        %{"new_state" => %{"counter" => new_counter}, "actions" => []}
      end)

    assert_receive :worker_ready, 500

    envelope = %{
      "id" => "e-1",
      "type" => "event",
      "source" => "esr://localhost/adapter/feishu",
      "principal_id" => "test_admin",
      "workspace_name" => "test-ws",
      "payload" => %{"event_type" => "msg_received", "args" => %{}}
    }

    send(GenServer.whereis({:via, Registry, {Esr.Entity.Registry, actor_id}}),
         {:inbound_event, envelope})

    # Poll for state update — send is async; the inner HandlerRouter.call is sync.
    Process.sleep(100)
    assert Entity.Server.get_state(actor_id) == %{"counter" => 1}

    send(worker.pid, :stop)
  end

  test "duplicate event by idempotency_key is deduped", %{actor_id: actor_id} do
    call_count = :counters.new(1, [])

    worker =
      start_fake_worker("noop", fn _payload ->
        :counters.add(call_count, 1, 1)
        %{"new_state" => %{"counter" => :counters.get(call_count, 1)}, "actions" => []}
      end)

    assert_receive :worker_ready, 500

    envelope = %{
      "id" => "e-dup",
      "type" => "event",
      "source" => "esr://localhost/adapter/x",
      "principal_id" => "test_admin",
      "workspace_name" => "test-ws",
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{"idempotency_key" => "oc_abc:m_1"}
      }
    }

    peer_pid = GenServer.whereis({:via, Registry, {Esr.Entity.Registry, actor_id}})

    send(peer_pid, {:inbound_event, envelope})
    Process.sleep(100)
    send(peer_pid, {:inbound_event, envelope})
    Process.sleep(100)

    assert :counters.get(call_count, 1) == 1, "handler should have been called only once"
    send(worker.pid, :stop)
  end

  test "handler timeout leaves state unchanged", %{actor_id: actor_id} do
    # No worker started — HandlerRouter.call will time out.
    envelope = %{
      "id" => "e-timeout",
      "type" => "event",
      "source" => "esr://localhost/adapter/x",
      "principal_id" => "test_admin",
      "workspace_name" => "test-ws",
      "payload" => %{"event_type" => "msg_received", "args" => %{}}
    }

    peer_pid = GenServer.whereis({:via, Registry, {Esr.Entity.Registry, actor_id}})
    send(peer_pid, {:inbound_event, envelope})

    # Allow the 200ms test-scoped timeout to elapse (see Entity.Server config)
    Process.sleep(300)

    # State is unchanged from initial
    assert Entity.Server.get_state(actor_id) == %{"counter" => 0}
  end
end

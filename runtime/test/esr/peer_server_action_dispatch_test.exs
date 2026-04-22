defmodule Esr.PeerServerActionDispatchTest do
  @moduledoc """
  PRD 01 F07 — PeerServer dispatches Emit / Route actions returned by
  HandlerRouter.call.

  P3-13: InvokeCommand is gone (Topology module deleted); session
  creation is now a SessionRouter control-plane operation.
  """

  use ExUnit.Case, async: false

  alias Esr.PeerServer
  alias Esr.TestSupport.AuthContext

  setup do
    # CAP-4: Lane B enforcement requires principal_id + grant on
    # every inbound_event. These tests care about action dispatch, not
    # capability enforcement — admin-grant the test principal so the
    # check always passes.
    AuthContext.load_admin("test_admin")
    :ok
  end

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

  defp start_peer(actor_id, opts \\ []) do
    {:ok, _} =
      start_supervised(
        {PeerServer,
         [
           actor_id: actor_id,
           actor_type: "test_actor",
           handler_module: "noop",
           initial_state: %{},
           handler_timeout: 500
         ] ++ opts}
      )

    GenServer.whereis({:via, Registry, {Esr.PeerRegistry, actor_id}})
  end

  defp send_event(peer_pid, id \\ "e-1") do
    send(peer_pid, {:inbound_event, %{
      "id" => id,
      "type" => "event",
      "source" => "esr://localhost/adapter/x",
      "principal_id" => "test_admin",
      "workspace_name" => "test-ws",
      "payload" => %{"event_type" => "msg_received", "args" => %{}}
    }})
  end

  test "Emit action broadcasts a directive on adapter:<name>/<actor_id>" do
    actor_id = "emit-test-#{System.unique_integer([:positive])}"

    worker =
      start_fake_worker("noop", fn _payload ->
        %{
          "new_state" => %{"ok" => true},
          "actions" => [
            %{
              "type" => "emit",
              "adapter" => "feishu-shared",
              "action" => "send_message",
              "args" => %{"chat_id" => "oc_abc", "content" => "hi"}
            }
          ]
        }
      end)

    assert_receive :worker_ready, 500

    # AdapterChannels join on "adapter:<name>/<instance_id>" where
    # instance_id is the bound actor_id. A bare "adapter:<name>"
    # broadcast would never reach them.
    Phoenix.PubSub.subscribe(EsrWeb.PubSub, "adapter:feishu-shared/" <> actor_id)

    peer_pid = start_peer(actor_id)
    send_event(peer_pid)

    assert_receive %Phoenix.Socket.Broadcast{event: "envelope", payload: env}, 2_000
    assert env["payload"]["adapter"] == "feishu-shared"
    assert env["payload"]["action"] == "send_message"
    assert env["payload"]["args"]["chat_id"] == "oc_abc"

    send(worker.pid, :stop)
  end

  test "Route action delivers {:inbound_event, _} to target actor" do
    source_id = "route-src-#{System.unique_integer([:positive])}"
    target_id = "route-tgt-#{System.unique_integer([:positive])}"

    worker =
      start_fake_worker("noop", fn _payload ->
        %{
          "new_state" => %{},
          "actions" => [
            %{
              "type" => "route",
              "target" => target_id,
              "msg" => %{"event_type" => "forwarded", "args" => %{"x" => 1}}
            }
          ]
        }
      end)

    assert_receive :worker_ready, 500

    # Target is self() via a fake Registry registration
    {:ok, _} = Registry.register(Esr.PeerRegistry, target_id, nil)

    peer_pid = start_peer(source_id)
    send_event(peer_pid)

    assert_receive {:inbound_event, routed}, 2_000
    assert routed["payload"]["event_type"] == "forwarded"

    Registry.unregister(Esr.PeerRegistry, target_id)
    send(worker.pid, :stop)
  end

  test "Route to unknown target fires telemetry (not a crash)" do
    actor_id = "route-orphan-#{System.unique_integer([:positive])}"

    worker =
      start_fake_worker("noop", fn _payload ->
        %{
          "new_state" => %{},
          "actions" => [
            %{"type" => "route", "target" => "does-not-exist", "msg" => "x"}
          ]
        }
      end)

    assert_receive :worker_ready, 500

    :telemetry.attach(
      "test-orphan-route",
      [:esr, :route, :target_missing],
      fn _e, _m, metadata, pid -> send(pid, {:orphan, metadata}) end,
      self()
    )

    peer_pid = start_peer(actor_id)
    send_event(peer_pid)

    assert_receive {:orphan, metadata}, 2_000
    assert metadata[:target] == "does-not-exist"

    :telemetry.detach("test-orphan-route")
    send(worker.pid, :stop)
  end
end

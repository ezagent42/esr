defmodule Esr.PeerServerActionDispatchTest do
  @moduledoc """
  PRD 01 F07 — PeerServer dispatches Emit actions returned by
  HandlerRouter.call.

  P3-13: InvokeCommand deleted (Topology module gone); session
  creation is now a Scope.Router control-plane operation.

  P3-16: Route action deleted (cross-esrd routing removed per spec
  §2.9); directive-returning handlers flow through the peer chain.
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

  # P3-16: the "Route action" + "Route to unknown target" tests were
  # removed with the `dispatch_action "route"` clause. Cross-esrd
  # routing is replaced by the per-session peer chain per spec §2.9.

  test "unknown action type emits [:esr, :action, :unknown]" do
    actor_id = "unknown-act-#{System.unique_integer([:positive])}"

    worker =
      start_fake_worker("noop", fn _payload ->
        %{
          "new_state" => %{},
          "actions" => [%{"type" => "route", "target" => "x", "msg" => "y"}]
        }
      end)

    assert_receive :worker_ready, 500

    :telemetry.attach(
      "test-unknown-action-#{:erlang.unique_integer()}",
      [:esr, :action, :unknown],
      fn _e, _m, metadata, pid -> send(pid, {:unknown, metadata}) end,
      self()
    )

    peer_pid = start_peer(actor_id)
    send_event(peer_pid)

    assert_receive {:unknown, metadata}, 2_000
    assert metadata[:action]["type"] == "route"

    send(worker.pid, :stop)
  end
end

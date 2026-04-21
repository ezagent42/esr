defmodule Esr.PeerServerEmitAckTest do
  @moduledoc """
  PRD 01 F07 C2 follow-up — Emit awaits directive_ack.

  PeerServer tracks a pending_directives map keyed by directive id.
  On ack arrival (via Phoenix.PubSub topic `directive_ack:<id>`) it
  emits `[:esr, :emit, :completed]` for ok acks and
  `[:esr, :emit, :failed]` for error acks. If no ack lands within
  the configured timeout, a periodic deadline scan emits
  `[:esr, :emit, :failed]` with reason :timeout.
  """

  use ExUnit.Case, async: false

  alias Esr.PeerServer
  alias Esr.TestSupport.AuthContext

  setup do
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

  defp send_event(peer_pid) do
    send(peer_pid, {:inbound_event, %{
      "id" => "e-1",
      "type" => "event",
      "source" => "esr://localhost/adapter/x",
      "principal_id" => "test_admin",
      "workspace_name" => "test-ws",
      "payload" => %{"event_type" => "msg_received", "args" => %{}}
    }})
  end

  defp emit_action do
    %{
      "type" => "emit",
      "adapter" => "feishu-shared",
      "action" => "send_message",
      "args" => %{"chat_id" => "oc_abc"}
    }
  end

  test "ok directive_ack emits [:esr, :emit, :completed]" do
    actor_id = "emit-ack-ok-#{System.unique_integer([:positive])}"

    worker =
      start_fake_worker("noop", fn _payload ->
        %{"new_state" => %{}, "actions" => [emit_action()]}
      end)

    assert_receive :worker_ready, 500

    # Subscribe to the directive broadcast so we can grab the id and
    # respond with an ack.
    Phoenix.PubSub.subscribe(EsrWeb.PubSub, "adapter:feishu-shared/" <> actor_id)

    :telemetry.attach(
      "emit-completed-#{:erlang.unique_integer()}",
      [:esr, :emit, :completed],
      fn _e, _m, metadata, pid -> send(pid, {:completed, metadata}) end,
      self()
    )

    peer_pid = start_peer(actor_id)
    send_event(peer_pid)

    assert_receive %Phoenix.Socket.Broadcast{event: "envelope", payload: env}, 2_000
    id = env["id"]

    Phoenix.PubSub.broadcast(
      EsrWeb.PubSub,
      "directive_ack:" <> id,
      {:directive_ack, %{"id" => id, "payload" => %{"ok" => true}}}
    )

    assert_receive {:completed, metadata}, 1_000
    assert metadata[:actor_id] == actor_id
    assert metadata[:directive_id] == id

    send(worker.pid, :stop)
  end

  test "error directive_ack emits [:esr, :emit, :failed]" do
    actor_id = "emit-ack-err-#{System.unique_integer([:positive])}"

    worker =
      start_fake_worker("noop", fn _payload ->
        %{"new_state" => %{}, "actions" => [emit_action()]}
      end)

    assert_receive :worker_ready, 500

    Phoenix.PubSub.subscribe(EsrWeb.PubSub, "adapter:feishu-shared/" <> actor_id)

    :telemetry.attach(
      "emit-failed-#{:erlang.unique_integer()}",
      [:esr, :emit, :failed],
      fn _e, _m, metadata, pid -> send(pid, {:failed, metadata}) end,
      self()
    )

    peer_pid = start_peer(actor_id)
    send_event(peer_pid)

    assert_receive %Phoenix.Socket.Broadcast{event: "envelope", payload: env}, 2_000
    id = env["id"]

    Phoenix.PubSub.broadcast(
      EsrWeb.PubSub,
      "directive_ack:" <> id,
      {:directive_ack,
       %{"id" => id, "payload" => %{"ok" => false, "error" => "boom"}}}
    )

    assert_receive {:failed, metadata}, 1_000
    assert metadata[:actor_id] == actor_id
    assert metadata[:directive_id] == id
    assert metadata[:reason] != :timeout

    send(worker.pid, :stop)
  end

  test "no ack within directive_timeout → [:esr, :emit, :failed] reason: :timeout" do
    actor_id = "emit-ack-timeout-#{System.unique_integer([:positive])}"

    worker =
      start_fake_worker("noop", fn _payload ->
        %{"new_state" => %{}, "actions" => [emit_action()]}
      end)

    assert_receive :worker_ready, 500

    :telemetry.attach(
      "emit-timeout-#{:erlang.unique_integer()}",
      [:esr, :emit, :failed],
      fn _e, _m, metadata, pid -> send(pid, {:failed, metadata}) end,
      self()
    )

    # 200ms directive timeout — no test subscriber sends ack, so it will
    # miss and the deadline scan must fire.
    peer_pid = start_peer(actor_id, directive_timeout: 200)
    send_event(peer_pid)

    assert_receive {:failed, metadata}, 2_000
    assert metadata[:actor_id] == actor_id
    assert metadata[:reason] == :timeout

    send(worker.pid, :stop)
  end
end

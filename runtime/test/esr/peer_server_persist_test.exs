defmodule Esr.PeerServerPersistTest do
  @moduledoc """
  PRD 01 F18 + spec §7.4 — PeerServer persists `new_state` to
  `Esr.Persistence.Ets` BEFORE dispatching any returned actions, so a
  crash between state update and action emit never leaks directives
  for a state the system has no record of.
  """

  use ExUnit.Case, async: false

  alias Esr.PeerServer
  alias Esr.Persistence.Ets, as: PersistStore

  @table :esr_actor_states

  setup do
    PersistStore.clear(@table)
    :ok
  end

  defp start_worker(handler_module, reply_shaper) do
    topic = "handler:" <> handler_module <> "/default"
    test_pid = self()

    Task.async(fn ->
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, topic)
      send(test_pid, :worker_ready)
      worker_loop(reply_shaper)
    end)
  end

  defp worker_loop(reply_shaper) do
    receive do
      %Phoenix.Socket.Broadcast{event: "envelope", payload: env} ->
        payload = reply_shaper.(env["payload"])

        Phoenix.PubSub.broadcast(
          EsrWeb.PubSub,
          "handler_reply:" <> env["id"],
          {:handler_reply, %{"id" => env["id"], "payload" => payload}}
        )

        worker_loop(reply_shaper)

      :stop ->
        :ok
    after
      5_000 -> :timeout
    end
  end

  defp start_peer(actor_id, handler, opts \\ []) do
    {:ok, _} =
      start_supervised(
        {PeerServer,
         [
           actor_id: actor_id,
           actor_type: "persist_test",
           handler_module: handler,
           initial_state: %{"counter" => 0},
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
      "payload" => %{"event_type" => "tick", "args" => %{}}
    }})
  end

  test "new_state lands in Persistence.Ets after a successful handler call" do
    handler = "persist-ok-#{System.unique_integer([:positive])}"
    actor_id = "persist-peer-#{System.unique_integer([:positive])}"

    _worker =
      start_worker(handler, fn _payload ->
        %{"new_state" => %{"counter" => 42}, "actions" => []}
      end)

    assert_receive :worker_ready, 500

    :telemetry.attach(
      "persist-invoked-#{:erlang.unique_integer()}",
      [:esr, :handler, :invoked],
      fn _e, _m, metadata, pid -> send(pid, {:invoked, metadata}) end,
      self()
    )

    peer_pid = start_peer(actor_id, handler)
    send_event(peer_pid)

    assert_receive {:invoked, _metadata}, 2_000

    assert {:ok, %{"counter" => 42}} = PersistStore.get(@table, actor_id)
  end

  test "init/1 rehydrates from Persistence.Ets when the actor_id has a prior state" do
    actor_id = "rehydrate-peer-#{System.unique_integer([:positive])}"

    # Pre-seed ETS as if a prior peer had stored this state.
    :ok = PersistStore.put(@table, actor_id, %{"counter" => 17, "name" => "kept"})

    {:ok, _pid} =
      PeerServer.start_link(
        actor_id: actor_id,
        actor_type: "rehydrate_test",
        handler_module: "noop.handler",
        # initial_state would normally win on a fresh spawn; prior
        # persisted state must override since it represents the
        # last committed transition (spec §7.4).
        initial_state: %{"counter" => 0},
        handler_timeout: 500
      )

    assert PeerServer.get_state(actor_id) == %{"counter" => 17, "name" => "kept"}
  end

  test "persist-then-emit ordering: when the handler returns an action, the ETS row is in place BEFORE the directive lands" do
    handler = "persist-order-#{System.unique_integer([:positive])}"
    actor_id = "persist-ord-peer-#{System.unique_integer([:positive])}"

    _worker =
      start_worker(handler, fn _payload ->
        %{
          "new_state" => %{"stored" => true},
          "actions" => [
            %{
              "type" => "emit",
              "adapter" => "t",
              "action" => "noop",
              "args" => %{}
            }
          ]
        }
      end)

    assert_receive :worker_ready, 500

    Phoenix.PubSub.subscribe(EsrWeb.PubSub, "adapter:t/" <> actor_id)

    peer_pid = start_peer(actor_id, handler)
    send_event(peer_pid)

    # When the directive arrives on the adapter topic, the persisted
    # state must already be observable. Spec §7.4 guarantees
    # persist-then-emit.
    assert_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 2_000
    assert {:ok, %{"stored" => true}} = PersistStore.get(@table, actor_id)
  end
end

defmodule Esr.PeerServerInvokeCommandTest do
  @moduledoc """
  PRD 01 F07 C5 — InvokeCommand action dispatches to
  `Esr.Topology.Instantiator` via a named artifact registered in
  `Esr.Topology.Registry`. The dispatch happens asynchronously (in a
  Task) so the PeerServer mailbox is not blocked by the
  init_directive wait.
  """

  use ExUnit.Case, async: false

  alias Esr.PeerServer
  alias Esr.Topology.Registry, as: TopoRegistry

  setup do
    for handle <- TopoRegistry.list_all(), do: TopoRegistry.deactivate(handle)

    for {_id, pid, _type, _mods} <- DynamicSupervisor.which_children(Esr.PeerSupervisor) do
      DynamicSupervisor.terminate_child(Esr.PeerSupervisor, pid)
    end

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

  defp start_peer(actor_id, handler_module) do
    {:ok, _} =
      start_supervised(
        {PeerServer,
         [
           actor_id: actor_id,
           actor_type: "ic_test",
           handler_module: handler_module,
           initial_state: %{},
           handler_timeout: 500
         ]}
      )

    GenServer.whereis({:via, Registry, {Esr.PeerRegistry, actor_id}})
  end

  defp send_event(peer_pid) do
    send(peer_pid, {:inbound_event, %{
      "id" => "e-ic",
      "type" => "event",
      "source" => "esr://localhost/adapter/x",
      "payload" => %{"event_type" => "tick", "args" => %{}}
    }})
  end

  defp simple_artifact do
    %{
      "name" => "ic-sub",
      "params" => ["n"],
      "nodes" => [
        %{"id" => "ic-node:{{n}}", "actor_type" => "t", "handler" => "noop.handler"}
      ],
      "edges" => []
    }
  end

  test "put_artifact/2 + get_artifact/1 store and retrieve a compiled topology" do
    assert :ok = TopoRegistry.put_artifact("ic-sub", simple_artifact())
    assert {:ok, art} = TopoRegistry.get_artifact("ic-sub")
    assert art["name"] == "ic-sub"
  end

  test "get_artifact/1 returns :error for unknown name" do
    assert :error = TopoRegistry.get_artifact("nope")
  end

  test "invoke_command action instantiates the artifact and fires [:esr, :topology, :activated]" do
    :ok = TopoRegistry.put_artifact("ic-sub", simple_artifact())

    handler = "ic-#{System.unique_integer([:positive])}"
    source_actor = "ic-src-#{System.unique_integer([:positive])}"

    _worker =
      start_fake_worker(handler, fn _payload ->
        %{
          "new_state" => %{},
          "actions" => [
            %{
              "type" => "invoke_command",
              "name" => "ic-sub",
              "params" => %{"n" => "42"}
            }
          ]
        }
      end)

    assert_receive :worker_ready, 500

    :telemetry.attach(
      "ic-activated-#{:erlang.unique_integer()}",
      [:esr, :topology, :activated],
      fn _e, _m, metadata, pid -> send(pid, {:activated, metadata}) end,
      self()
    )

    peer_pid = start_peer(source_actor, handler)
    send_event(peer_pid)

    assert_receive {:activated, metadata}, 3_000
    assert metadata[:name] == "ic-sub"
    assert metadata[:params] == %{"n" => "42"}

    # The target peer was spawned under PeerSupervisor.
    assert {:ok, _} = Esr.PeerRegistry.lookup("ic-node:42")
  end

  test "invoke_command with unknown name emits [:esr, :invoke_command, :unknown]" do
    handler = "ic-unk-#{System.unique_integer([:positive])}"
    source_actor = "ic-unk-src-#{System.unique_integer([:positive])}"

    _worker =
      start_fake_worker(handler, fn _payload ->
        %{
          "new_state" => %{},
          "actions" => [
            %{
              "type" => "invoke_command",
              "name" => "no-such-artifact",
              "params" => %{}
            }
          ]
        }
      end)

    assert_receive :worker_ready, 500

    :telemetry.attach(
      "ic-unk-#{:erlang.unique_integer()}",
      [:esr, :invoke_command, :unknown],
      fn _e, _m, metadata, pid -> send(pid, {:unknown, metadata}) end,
      self()
    )

    peer_pid = start_peer(source_actor, handler)
    send_event(peer_pid)

    assert_receive {:unknown, metadata}, 2_000
    assert metadata[:name] == "no-such-artifact"
  end
end

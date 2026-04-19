defmodule Esr.Topology.StopCascadeTest do
  @moduledoc """
  PRD 01 F14 — Esr.Topology.Registry.deactivate stops peer actors in
  REVERSE depends_on (spawn) order and emits
  [:esr, :topology, :deactivated].
  """

  use ExUnit.Case, async: false

  alias Esr.Topology.Instantiator
  alias Esr.Topology.Registry, as: TopoRegistry

  setup do
    for handle <- TopoRegistry.list_all(), do: TopoRegistry.deactivate(handle)

    for {_id, pid, _type, _mods} <- DynamicSupervisor.which_children(Esr.PeerSupervisor) do
      DynamicSupervisor.terminate_child(Esr.PeerSupervisor, pid)
    end

    :ok
  end

  defp chain_artifact do
    %{
      "name" => "stop-chain",
      "params" => ["n"],
      "nodes" => [
        %{"id" => "a:{{n}}", "actor_type" => "t", "handler" => "h"},
        %{
          "id" => "b:{{n}}",
          "actor_type" => "t",
          "handler" => "h",
          "depends_on" => ["a:{{n}}"]
        },
        %{
          "id" => "c:{{n}}",
          "actor_type" => "t",
          "handler" => "h",
          "depends_on" => ["b:{{n}}"]
        }
      ],
      "edges" => []
    }
  end

  defp wait_until_unregistered(_id, 0), do: :ok

  defp wait_until_unregistered(id, tries) do
    case Esr.PeerRegistry.lookup(id) do
      :error ->
        :ok

      {:ok, _} ->
        Process.sleep(10)
        wait_until_unregistered(id, tries - 1)
    end
  end

  test "deactivate unregisters every spawned peer" do
    {:ok, handle} = Instantiator.instantiate(chain_artifact(), %{"n" => "1"})

    # All peers exist pre-stop
    assert {:ok, _} = Esr.PeerRegistry.lookup("a:1")
    assert {:ok, _} = Esr.PeerRegistry.lookup("b:1")
    assert {:ok, _} = Esr.PeerRegistry.lookup("c:1")

    assert :ok = TopoRegistry.deactivate(handle)

    # All peers gone (with a short poll for async Registry cleanup)
    for id <- ~w(a:1 b:1 c:1), do: wait_until_unregistered(id, 50)

    assert :error = Esr.PeerRegistry.lookup("a:1")
    assert :error = Esr.PeerRegistry.lookup("b:1")
    assert :error = Esr.PeerRegistry.lookup("c:1")
    assert :error = TopoRegistry.lookup("stop-chain", %{"n" => "1"})
  end

  test "deactivate fires [:esr, :topology, :deactivated] telemetry" do
    {:ok, handle} = Instantiator.instantiate(chain_artifact(), %{"n" => "2"})

    :telemetry.attach(
      "test-deactivated",
      [:esr, :topology, :deactivated],
      fn _event, _m, metadata, pid -> send(pid, {:deactivated, metadata}) end,
      self()
    )

    TopoRegistry.deactivate(handle)

    assert_receive {:deactivated, metadata}, 500
    assert metadata[:name] == "stop-chain"
    assert metadata[:params] == %{"n" => "2"}

    :telemetry.detach("test-deactivated")
  end

  test "stop order is reverse of spawn order (c, b, a)" do
    {:ok, handle} = Instantiator.instantiate(chain_artifact(), %{"n" => "3"})

    :telemetry.attach(
      "test-peer-stopped",
      [:esr, :peer_server, :stopped],
      fn _event, _m, metadata, pid -> send(pid, {:peer_stopped, metadata[:actor_id]}) end,
      self()
    )

    TopoRegistry.deactivate(handle)

    assert_receive {:peer_stopped, "c:3"}, 500
    assert_receive {:peer_stopped, "b:3"}, 500
    assert_receive {:peer_stopped, "a:3"}, 500

    :telemetry.detach("test-peer-stopped")
  end
end

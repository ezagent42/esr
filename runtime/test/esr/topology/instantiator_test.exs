defmodule Esr.Topology.InstantiatorTest do
  @moduledoc """
  PRD 01 F13 — Esr.Topology.Instantiator spawns PeerServers in
  depends_on topological order and registers the result in
  Esr.Topology.Registry.
  """

  use ExUnit.Case, async: false

  alias Esr.Topology.Instantiator
  alias Esr.Topology.Registry, as: TopoRegistry

  setup do
    # Clean slate: drop topo handles and terminate every live PeerServer.
    for handle <- TopoRegistry.list_all() do
      TopoRegistry.deactivate(handle)
    end

    for {_id, pid, _type, _mods} <- DynamicSupervisor.which_children(Esr.PeerSupervisor) do
      DynamicSupervisor.terminate_child(Esr.PeerSupervisor, pid)
    end

    :ok
  end

  defp artifact_single_node do
    %{
      "name" => "single-node",
      "params" => ["thread_id"],
      "nodes" => [
        %{
          "id" => "thread:{{thread_id}}",
          "actor_type" => "feishu_thread_proxy",
          "handler" => "feishu_thread.on_msg"
        }
      ],
      "edges" => []
    }
  end

  defp artifact_chain do
    %{
      "name" => "chain",
      "params" => ["thread_id"],
      "nodes" => [
        %{
          "id" => "thread:{{thread_id}}",
          "actor_type" => "feishu_thread_proxy",
          "handler" => "feishu_thread.on_msg"
        },
        %{
          "id" => "tmux:{{thread_id}}",
          "actor_type" => "tmux_proxy",
          "handler" => "tmux_proxy.on_msg",
          "adapter" => "cc_tmux",
          "depends_on" => ["thread:{{thread_id}}"]
        },
        %{
          "id" => "cc:{{thread_id}}",
          "actor_type" => "cc_proxy",
          "handler" => "cc_session.on_msg",
          "depends_on" => ["tmux:{{thread_id}}"]
        }
      ],
      "edges" => [
        ["thread:{{thread_id}}", "tmux:{{thread_id}}"],
        ["tmux:{{thread_id}}", "cc:{{thread_id}}"]
      ]
    }
  end

  test "happy path: instantiate spawns one PeerServer per node" do
    {:ok, handle} = Instantiator.instantiate(artifact_single_node(), %{"thread_id" => "foo"})
    assert handle.name == "single-node"
    assert handle.params == %{"thread_id" => "foo"}
    assert handle.peer_ids == ["thread:foo"]

    # The PeerServer is registered in Esr.PeerRegistry
    assert {:ok, _pid} = Esr.PeerRegistry.lookup("thread:foo")
  end

  test "chain topology spawns nodes in depends_on order" do
    {:ok, handle} = Instantiator.instantiate(artifact_chain(), %{"thread_id" => "bar"})

    # peer_ids are in topo order (thread first, tmux, cc last)
    assert handle.peer_ids == ["thread:bar", "tmux:bar", "cc:bar"]
  end

  test "missing param returns {:error, {:missing_params, [...]}}" do
    assert {:error, {:missing_params, missing}} =
             Instantiator.instantiate(artifact_single_node(), %{})

    assert "thread_id" in missing
  end

  test "cycle in depends_on returns {:error, :cycle_in_depends_on}" do
    cyclic = %{
      "name" => "cyclic",
      "params" => [],
      "nodes" => [
        %{
          "id" => "a",
          "actor_type" => "t",
          "handler" => "h",
          "depends_on" => ["b"]
        },
        %{
          "id" => "b",
          "actor_type" => "t",
          "handler" => "h",
          "depends_on" => ["a"]
        }
      ],
      "edges" => []
    }

    assert {:error, :cycle_in_depends_on} = Instantiator.instantiate(cyclic, %{})
  end

  test "idempotent: instantiate twice with same params returns same handle" do
    {:ok, a} = Instantiator.instantiate(artifact_single_node(), %{"thread_id" => "baz"})
    {:ok, b} = Instantiator.instantiate(artifact_single_node(), %{"thread_id" => "baz"})
    assert a == b
  end

  test "adapter binding: node with adapter creates AdapterHub topic binding" do
    {:ok, _handle} = Instantiator.instantiate(artifact_chain(), %{"thread_id" => "qux"})

    # The tmux node declares adapter="cc_tmux" and has id tmux:qux.
    # Binding topic is adapter:<adapter_name>/<node_id>; v0.1 simplifies to
    # adapter:<adapter_name> with the node_id as actor_id.
    assert {:ok, actor_id} =
             Esr.AdapterHub.Registry.lookup("adapter:cc_tmux/tmux:qux")

    assert actor_id == "tmux:qux"
  end
end

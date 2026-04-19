defmodule Esr.Topology.InitDirectiveTest do
  @moduledoc """
  PRD 01 F13b — nodes carrying ``init_directive`` dispatch the
  directive at instantiate time, wait for the ack, and roll back
  predecessor spawns on failure.
  """

  use ExUnit.Case, async: false

  alias Esr.Topology.Instantiator
  alias Esr.Topology.Registry, as: TopoRegistry

  setup do
    for handle <- TopoRegistry.list_all(), do: TopoRegistry.deactivate(handle)

    # Terminate every live PeerServer so ids don't leak across tests.
    for {_id, pid, _type, _mods} <- DynamicSupervisor.which_children(Esr.PeerSupervisor) do
      DynamicSupervisor.terminate_child(Esr.PeerSupervisor, pid)
    end

    :ok
  end

  # Simulates an adapter process by subscribing to the adapter topic,
  # receiving the "directive" broadcast, and responding with an ack
  # whose shape the test controls.
  defp start_fake_adapter(topic, ack_shaper) do
    test_pid = self()

    Task.async(fn ->
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, topic)
      send(test_pid, :fake_adapter_ready)

      receive do
        %Phoenix.Socket.Broadcast{event: "directive", payload: env} ->
          ack = ack_shaper.(env)

          Phoenix.PubSub.broadcast(
            EsrWeb.PubSub,
            "directive_ack:" <> env["id"],
            {:directive_ack, %{"id" => env["id"], "payload" => ack}}
          )
      after
        5_000 -> :timeout
      end
    end)
  end

  defp artifact_with_init do
    %{
      "name" => "init-dir-test",
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
          "depends_on" => ["thread:{{thread_id}}"],
          "init_directive" => %{
            "action" => "new_session",
            "args" => %{"session_name" => "{{thread_id}}", "start_cmd" => "/bin/echo"}
          }
        },
        %{
          "id" => "cc:{{thread_id}}",
          "actor_type" => "cc_proxy",
          "handler" => "cc_session.on_msg",
          "depends_on" => ["tmux:{{thread_id}}"]
        }
      ],
      "edges" => []
    }
  end

  test "init_directive with ok ack → all nodes spawned" do
    adapter_topic = "adapter:cc_tmux/tmux:foo"

    _adapter =
      start_fake_adapter(adapter_topic, fn env ->
        # Verify substitution worked
        assert env["payload"]["args"]["session_name"] == "foo"
        %{"ok" => true, "result" => %{"session" => "foo"}}
      end)

    assert_receive :fake_adapter_ready, 500

    assert {:ok, handle} =
             Instantiator.instantiate(
               artifact_with_init(),
               %{"thread_id" => "foo"},
               init_directive_timeout: 1_000
             )

    assert handle.peer_ids == ["thread:foo", "tmux:foo", "cc:foo"]
    assert {:ok, _} = Esr.PeerRegistry.lookup("cc:foo")
  end

  test "init_directive ack error → rollback predecessor spawns" do
    adapter_topic = "adapter:cc_tmux/tmux:bar"

    _adapter =
      start_fake_adapter(adapter_topic, fn _env ->
        %{"ok" => false, "error" => %{"type" => "TmuxFail", "message" => "boom"}}
      end)

    assert_receive :fake_adapter_ready, 500

    assert {:error, {:init_directive_failed, "tmux:bar", reason}} =
             Instantiator.instantiate(
               artifact_with_init(),
               %{"thread_id" => "bar"},
               init_directive_timeout: 1_000
             )

    assert reason["ok"] == false

    # Predecessor (thread:bar) should be stopped; dependent (cc:bar) never started.
    # Registry cleanup after terminate_child is async — poll briefly.
    wait_until_unregistered("thread:bar", 50)
    assert :error = Esr.PeerRegistry.lookup("thread:bar")
    assert :error = Esr.PeerRegistry.lookup("cc:bar")
    assert :error = TopoRegistry.lookup("init-dir-test", %{"thread_id" => "bar"})
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

  test "init_directive timeout → rollback" do
    # No adapter started — directive will time out
    assert {:error, {:init_directive_failed, "tmux:baz", :timeout}} =
             Instantiator.instantiate(
               artifact_with_init(),
               %{"thread_id" => "baz"},
               init_directive_timeout: 200
             )

    assert :error = Esr.PeerRegistry.lookup("thread:baz")
    assert :error = Esr.PeerRegistry.lookup("tmux:baz")
  end
end

defmodule Esr.PeerServerTest do
  @moduledoc """
  PRD 01 F05 — PeerServer skeleton. Verifies initial state is stored
  and retrievable; registers itself in PeerRegistry; emits the
  `[:esr, :actor, :spawned]` telemetry event on init.

  Event handling (F06), action dispatch (F07), pause/resume (F20) come
  in later FRs.
  """

  use ExUnit.Case, async: false

  setup do
    for {actor_id, _pid} <- Esr.PeerRegistry.list_all() do
      Registry.unregister(Esr.PeerRegistry, actor_id)
    end

    :ok
  end

  describe "start_link/1" do
    test "starts a PeerServer and registers it in PeerRegistry" do
      {:ok, pid} =
        Esr.PeerServer.start_link(
          actor_id: "test:1",
          actor_type: "test_type",
          handler_module: "noop.handler",
          initial_state: %{}
        )

      assert Process.alive?(pid)
      assert {:ok, ^pid} = Esr.PeerRegistry.lookup("test:1")
    end

    test "emits [:esr, :actor, :spawned] telemetry on init" do
      ref = make_ref()
      test_pid = self()

      handler = fn event, measurements, metadata, _config ->
        send(test_pid, {ref, event, measurements, metadata})
      end

      :telemetry.attach(
        "peer-server-test-#{:erlang.unique_integer()}",
        [:esr, :actor, :spawned],
        handler,
        nil
      )

      {:ok, _pid} =
        Esr.PeerServer.start_link(
          actor_id: "test:spawned",
          actor_type: "test_type",
          handler_module: "noop.handler",
          initial_state: %{}
        )

      assert_receive {^ref, [:esr, :actor, :spawned], _measurements, metadata}
      assert metadata.actor_id == "test:spawned"
      assert metadata.actor_type == "test_type"
    end
  end

  describe "get_state/1" do
    test "returns the initial_state after start" do
      {:ok, _pid} =
        Esr.PeerServer.start_link(
          actor_id: "test:state",
          actor_type: "test_type",
          handler_module: "noop.handler",
          initial_state: %{counter: 7}
        )

      assert Esr.PeerServer.get_state("test:state") == %{counter: 7}
    end
  end
end

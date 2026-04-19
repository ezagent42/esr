defmodule Esr.PeerSupervisorTest do
  @moduledoc """
  PRD 01 F04 — DynamicSupervisor that owns PeerServer children.
  Verifies start_peer/stop_peer round-trip and that `:one_for_one`
  isolates sibling peers from each other's crashes (Track D gate).
  """

  use ExUnit.Case, async: false

  setup do
    # PeerSupervisor + PeerRegistry are started by the Application for the
    # whole test run. Clean up any peers from prior tests.
    for {actor_id, _pid} <- Esr.PeerRegistry.list_all() do
      _ = Esr.PeerSupervisor.stop_peer(actor_id)
    end

    :ok
  end

  describe "start_peer/1" do
    test "spawns a PeerServer under the supervisor" do
      {:ok, pid} =
        Esr.PeerSupervisor.start_peer(
          actor_id: "cc:sess-A",
          actor_type: "cc_session",
          handler_module: "cc_session.on_msg",
          initial_state: %{}
        )

      assert Process.alive?(pid)
      assert {:ok, ^pid} = Esr.PeerRegistry.lookup("cc:sess-A")

      children = DynamicSupervisor.which_children(Esr.PeerSupervisor)
      assert Enum.any?(children, fn {_id, child_pid, :worker, _} -> child_pid == pid end)
    end
  end

  describe "stop_peer/1" do
    test "terminates the peer and unregisters it" do
      {:ok, pid} =
        Esr.PeerSupervisor.start_peer(
          actor_id: "cc:sess-B",
          actor_type: "cc_session",
          handler_module: "cc_session.on_msg",
          initial_state: %{}
        )

      ref = Process.monitor(pid)
      assert :ok = Esr.PeerSupervisor.stop_peer("cc:sess-B")
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500

      refute Process.alive?(pid)
      assert Esr.PeerRegistry.lookup("cc:sess-B") == :error
    end

    test "returns {:error, :not_found} for unknown actor_id" do
      assert {:error, :not_found} = Esr.PeerSupervisor.stop_peer("cc:sess-does-not-exist")
    end
  end

  describe "one_for_one isolation" do
    test "sibling peer survives a co-spawned peer crash" do
      {:ok, a_pid} =
        Esr.PeerSupervisor.start_peer(
          actor_id: "cc:sibling-A",
          actor_type: "cc_session",
          handler_module: "cc_session.on_msg",
          initial_state: %{}
        )

      {:ok, b_pid} =
        Esr.PeerSupervisor.start_peer(
          actor_id: "cc:sibling-B",
          actor_type: "cc_session",
          handler_module: "cc_session.on_msg",
          initial_state: %{}
        )

      ref = Process.monitor(a_pid)
      Process.exit(a_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^a_pid, _}, 500

      # Sibling B must still be alive.
      assert Process.alive?(b_pid)
      assert {:ok, ^b_pid} = Esr.PeerRegistry.lookup("cc:sibling-B")
    end
  end
end

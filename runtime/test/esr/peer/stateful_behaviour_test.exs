defmodule Esr.Peer.StatefulBehaviourTest do
  @moduledoc """
  P5-6 — Esr.Peer.Stateful must NOT declare @callback init/1.
  init is GenServer's (or Esr.OSProcess's) callback; Stateful owns the
  chain-specific upstream/downstream callbacks only. This guards
  against the conflicting-behaviour compile warning regressing.

  PR-6 B1 — Extended to cover the new overridable defaults the macro
  injects (no-op handle_upstream/handle_downstream, dual-shape
  start_link) and the shared `dispatch_upstream/3` GenServer↔Stateful
  bridge.
  """
  use ExUnit.Case, async: true

  test "Esr.Peer.Stateful does not declare init/1 as a callback" do
    callbacks = Esr.Peer.Stateful.behaviour_info(:callbacks)
    refute {:init, 1} in callbacks,
      "Esr.Peer.Stateful should leave init/1 to GenServer"
  end

  test "Esr.Peer.Stateful still declares handle_upstream/2 and handle_downstream/2" do
    callbacks = Esr.Peer.Stateful.behaviour_info(:callbacks)
    assert {:handle_upstream, 2} in callbacks
    assert {:handle_downstream, 2} in callbacks
  end

  describe "macro defaults" do
    defmodule MinimalPeer do
      use Esr.Peer.Stateful
      use GenServer

      @impl GenServer
      def init(args), do: {:ok, args}
    end

    test "MinimalPeer inherits default handle_upstream/2 as {:forward, [], state}" do
      assert MinimalPeer.handle_upstream(:any_msg, %{x: 1}) == {:forward, [], %{x: 1}}
    end

    test "MinimalPeer inherits default handle_downstream/2 as {:forward, [], state}" do
      assert MinimalPeer.handle_downstream(:any_msg, %{x: 1}) == {:forward, [], %{x: 1}}
    end

    test "MinimalPeer inherits dual-shape start_link/1 accepting map and keyword" do
      {:ok, pid_map} = MinimalPeer.start_link(%{x: 1})
      assert Process.alive?(pid_map)
      GenServer.stop(pid_map)

      {:ok, pid_kw} = MinimalPeer.start_link(x: 1)
      assert Process.alive?(pid_kw)
      GenServer.stop(pid_kw)
    end

    defmodule UpPeer do
      use Esr.Peer.Stateful
      use GenServer

      @impl GenServer
      def init(args), do: {:ok, args}

      @impl Esr.Peer.Stateful
      def handle_upstream(:drop_me, state), do: {:drop, :reason, state}
      def handle_upstream(:forward_me, state), do: {:forward, [:out], state}
      def handle_upstream(:reply_me, state), do: {:reply, :val, state}
    end

    test "dispatch_upstream translates :drop to {:noreply, state}" do
      assert Esr.Peer.Stateful.dispatch_upstream(:drop_me, %{a: 1}, UpPeer) ==
               {:noreply, %{a: 1}}
    end

    test "dispatch_upstream translates :forward to {:noreply, state}" do
      assert Esr.Peer.Stateful.dispatch_upstream(:forward_me, %{a: 1}, UpPeer) ==
               {:noreply, %{a: 1}}
    end

    test "dispatch_upstream translates :reply to {:noreply, state}" do
      assert Esr.Peer.Stateful.dispatch_upstream(:reply_me, %{a: 1}, UpPeer) ==
               {:noreply, %{a: 1}}
    end

    test "dispatch_upstream on a peer using default handle_upstream returns {:noreply, state}" do
      assert Esr.Peer.Stateful.dispatch_upstream(:anything, %{a: 1}, MinimalPeer) ==
               {:noreply, %{a: 1}}
    end

    defmodule DownPeer do
      use Esr.Peer.Stateful
      use GenServer

      @impl GenServer
      def init(args), do: {:ok, args}

      @impl Esr.Peer.Stateful
      def handle_downstream(:drop_me, state), do: {:drop, :reason, state}
      def handle_downstream(:forward_me, state), do: {:forward, [:out], state}
    end

    test "dispatch_downstream translates :drop and :forward to {:noreply, state}" do
      assert Esr.Peer.Stateful.dispatch_downstream(:drop_me, %{a: 1}, DownPeer) ==
               {:noreply, %{a: 1}}

      assert Esr.Peer.Stateful.dispatch_downstream(:forward_me, %{a: 1}, DownPeer) ==
               {:noreply, %{a: 1}}
    end
  end
end

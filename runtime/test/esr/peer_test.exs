defmodule Esr.PeerTest do
  use ExUnit.Case, async: true

  describe "Esr.Peer" do
    test "defines common metadata helpers" do
      # A module using either Peer.Proxy or Peer.Stateful gains a
      # peer_kind/0 helper that returns :proxy or :stateful.
      defmodule TestProxy do
        use Esr.Peer.Proxy
        def forward(_msg, _ctx), do: :ok
      end
      defmodule TestStateful do
        use Esr.Peer.Stateful
        def init(_), do: {:ok, %{}}
        def handle_upstream(_, state), do: {:forward, [], state}
        def handle_downstream(_, state), do: {:forward, [], state}
      end

      assert TestProxy.peer_kind() == :proxy
      assert TestStateful.peer_kind() == :stateful
    end

    test "Peer module exposes peer_kind/0 callback typing" do
      # The base module defines the @callback peer_kind/0 :: :proxy | :stateful
      assert {:peer_kind, 0} in Esr.Peer.behaviour_info(:callbacks)
    end
  end
end

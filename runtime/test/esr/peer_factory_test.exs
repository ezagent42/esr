defmodule Esr.PeerFactoryTest do
  use ExUnit.Case, async: false

  defmodule TestPeer do
    use Esr.Peer.Stateful
    use GenServer
    def init(args), do: {:ok, args}
    def handle_upstream(_, s), do: {:forward, [], s}
    def handle_downstream(_, s), do: {:forward, [], s}
    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    def handle_call(_, _, s), do: {:reply, :ok, s}
  end

  setup do
    {:ok, _sup} = DynamicSupervisor.start_link(strategy: :one_for_one, name: :test_peer_sup)
    # Stub Esr.Session.supervisor_name/1 to return our test supervisor
    Process.put(:peer_factory_sup_override, :test_peer_sup)
    :ok
  end

  test "spawn_peer starts a child under the session's supervisor" do
    assert {:ok, pid} =
             Esr.PeerFactory.spawn_peer("test-session-1", TestPeer, %{name: "p1"}, [], %{})

    assert Process.alive?(pid)
  end

  test "spawn_peer rejects unknown peer impl" do
    assert {:error, _} =
             Esr.PeerFactory.spawn_peer("test-session-1", NonExistentMod, %{}, [], %{})
  end

  test "PeerFactory.__info__(:functions) matches the declared public surface" do
    expected = [
      {:spawn_peer, 5},
      {:terminate_peer, 2},
      {:restart_peer, 2}
    ]

    actual =
      Esr.PeerFactory.__info__(:functions)
      |> Enum.filter(fn {k, _} -> not String.starts_with?(Atom.to_string(k), "__") end)

    for fn_arity <- expected do
      assert fn_arity in actual
    end
  end
end

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
    start_supervised!({Registry, keys: :unique, name: Esr.Session.Registry})
    :ok
  end

  test "spawn_peer resolves supervisor via Esr.Session.supervisor_name/1" do
    # Start a real Session with a real peers DynamicSupervisor
    {:ok, _sup} =
      Esr.Session.start_link(%{
        session_id: "pf-s1",
        agent_name: "cc",
        dir: "/tmp/x",
        chat_thread_key: %{chat_id: "oc", thread_id: "om"},
        metadata: %{}
      })

    assert {:ok, pid} =
             Esr.PeerFactory.spawn_peer("pf-s1", TestPeer, %{name: "p1"}, [], %{})

    assert Process.alive?(pid)
  end

  test "PeerFactory.__info__(:functions) matches the declared public surface" do
    expected = [
      {:spawn_peer, 5},
      {:terminate_peer, 2},
      {:restart_peer, 2},
      # Added in P2-1
      {:spawn_peer_bootstrap, 4}
    ]

    actual =
      Esr.PeerFactory.__info__(:functions)
      |> Enum.filter(fn {k, _} -> not String.starts_with?(Atom.to_string(k), "__") end)

    for fn_arity <- expected, do: assert(fn_arity in actual)
  end
end

defmodule Esr.EntityFactoryTest do
  use ExUnit.Case, async: false

  defmodule TestPeer do
    use Esr.Entity.Stateful
    use GenServer
    def init(args), do: {:ok, args}
    def handle_upstream(_, s), do: {:forward, [], s}
    def handle_downstream(_, s), do: {:forward, [], s}
    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    def handle_call(_, _, s), do: {:reply, :ok, s}
  end

  setup do
    # Drift from expansion doc: `Esr.Scope.Registry` is already started
    # by `Esr.Application` (P2-9 added it). Previously the test booted its
    # own Registry under the same name; now we just assert the app-level
    # one is up and reuse it.
    assert is_pid(Process.whereis(Esr.Scope.Registry))
    :ok
  end

  test "spawn_peer resolves supervisor via Esr.Scope.supervisor_name/1" do
    # Start a real Session with a real peers DynamicSupervisor
    {:ok, _sup} =
      Esr.Scope.start_link(%{
        session_id: "pf-s1",
        agent_name: "cc",
        dir: "/tmp/x",
        chat_thread_key: %{chat_id: "oc", thread_id: "om"},
        metadata: %{}
      })

    assert {:ok, pid} =
             Esr.Entity.Factory.spawn_peer("pf-s1", TestPeer, %{name: "p1"}, %{})

    assert Process.alive?(pid)
  end

  test "Entity.Factory.__info__(:functions) matches the declared public surface" do
    expected = [
      {:spawn_peer, 4},
      {:terminate_peer, 2},
      {:restart_peer, 2},
      # Added in P2-1; M-2.5 dropped the neighbors arg
      {:spawn_peer_bootstrap, 3}
    ]

    actual =
      Esr.Entity.Factory.__info__(:functions)
      |> Enum.filter(fn {k, _} -> not String.starts_with?(Atom.to_string(k), "__") end)

    for fn_arity <- expected, do: assert(fn_arity in actual)
  end
end

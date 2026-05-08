defmodule Esr.Entity.StatefulTest do
  use ExUnit.Case, async: true

  defmodule SumPeer do
    use Esr.Entity.Stateful

    @impl true
    def init(_), do: {:ok, %{total: 0}}

    @impl true
    def handle_upstream({:add, n}, state) do
      new = %{state | total: state.total + n}
      {:forward, [{:total, new.total}], new}
    end

    @impl true
    def handle_downstream({:reset}, _state), do: {:forward, [], %{total: 0}}
  end

  test "Peer.Stateful modules expose the behaviour callbacks" do
    assert {:init, 1} in SumPeer.module_info(:exports)
    assert {:handle_upstream, 2} in SumPeer.module_info(:exports)
    assert {:handle_downstream, 2} in SumPeer.module_info(:exports)
  end

  test "init returns the initial state" do
    assert {:ok, %{total: 0}} = SumPeer.init(%{})
  end

  test "handle_upstream updates state and emits forward msg" do
    {:ok, s0} = SumPeer.init(%{})
    assert {:forward, [{:total, 5}], %{total: 5}} = SumPeer.handle_upstream({:add, 5}, s0)
  end

  test "peer_kind/0 is :stateful" do
    assert SumPeer.peer_kind() == :stateful
  end
end

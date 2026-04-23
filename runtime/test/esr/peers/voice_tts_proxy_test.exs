defmodule Esr.Peers.VoiceTTSProxyTest do
  @moduledoc """
  P4a-6 — mirror of VoiceASRProxy for the TTS pool direction. Same
  acquire → call → release lifecycle, `@required_cap "peer_pool:voice_tts/acquire"`.
  """
  use ExUnit.Case, async: false

  alias Esr.Peers.VoiceTTSProxy

  defmodule DummyWorker do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    def init(_), do: {:ok, nil}
    # VoiceTTS.synthesize/3 routes via the `{:rpc, payload, timeout}` shape
    # injected by `Esr.Peer.PyWorker` (PR-6 B2).
    def handle_call({:rpc, _payload, _timeout}, _, s), do: {:reply, {:ok, "AUDIO"}, s}
  end

  setup do
    Process.put(:esr_cap_test_override, fn _, _ -> true end)

    pool_name = :"vtts_test_pool_#{:erlang.unique_integer([:positive])}"
    {:ok, pool} = Esr.PeerPool.start_link(name: pool_name, worker: DummyWorker, max: 2)

    on_exit(fn ->
      if Process.alive?(pool), do: GenServer.stop(pool)
    end)

    %{pool_name: pool_name}
  end

  test "forward/2 acquires, calls synthesize, releases", %{pool_name: pool_name} do
    assert {:ok, "AUDIO"} =
             VoiceTTSProxy.forward({:voice_tts, "hello"}, %{
               principal_id: "ou_test",
               pool_name: pool_name,
               acquire_timeout: 200
             })
  end

  test "capability denied short-circuits to {:drop, :cap_denied}", %{pool_name: pool_name} do
    Process.put(:esr_cap_test_override, fn _, _ -> false end)

    assert {:drop, :cap_denied} =
             VoiceTTSProxy.forward({:voice_tts, "hi"}, %{
               principal_id: "ou_test",
               pool_name: pool_name
             })
  end

  test "pool exhaustion returns {:drop, :pool_exhausted}" do
    pool_name = :"vtts_exhausted_#{:erlang.unique_integer([:positive])}"
    {:ok, _pool} = Esr.PeerPool.start_link(name: pool_name, worker: DummyWorker, max: 1)
    {:ok, _w} = Esr.PeerPool.acquire(pool_name)

    assert {:drop, :pool_exhausted} =
             VoiceTTSProxy.forward({:voice_tts, "hi"}, %{
               principal_id: "ou_test",
               pool_name: pool_name,
               acquire_timeout: 0
             })
  end
end

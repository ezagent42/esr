defmodule Esr.Entity.VoiceASRProxyTest do
  @moduledoc """
  P4a-6 — `Esr.Entity.VoiceASRProxy` is the one documented exception to
  §3.6's "static target" rule (alongside VoiceTTSProxy and the
  slash-handler fallback): on forward, it acquires a VoiceASR worker
  from the pool named by ctx, invokes `transcribe/2`, then releases.

  `@required_cap "peer_pool:voice_asr/acquire"` enforces the capability
  check at proxy boundary (PR-3 macro extension). Tests stub the
  capability via `Process.put(:esr_cap_test_override, fn _, _ -> true end)`.
  """
  use ExUnit.Case, async: false

  alias Esr.Entity.VoiceASRProxy

  defmodule DummyWorker do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    def init(_), do: {:ok, nil}
    # VoiceASR.transcribe/3 routes via the `{:rpc, payload, timeout}` shape
    # injected by `Esr.Entity.PyWorker` (PR-6 B2).
    def handle_call({:rpc, _payload, _timeout}, _, s), do: {:reply, {:ok, "MOCK"}, s}
  end

  # Re-uses the real Esr.Entity.Pool so the acquire/release contract is the
  # live contract, not a stub.
  setup do
    Process.put(:esr_cap_test_override, fn _, _ -> true end)

    pool_name = :"vasr_test_pool_#{:erlang.unique_integer([:positive])}"
    {:ok, pool} = Esr.Entity.Pool.start_link(name: pool_name, worker: DummyWorker, max: 2)

    on_exit(fn ->
      if Process.alive?(pool), do: GenServer.stop(pool)
    end)

    %{pool_name: pool_name, pool: pool}
  end

  test "forward/2 acquires, calls transcribe, releases", %{pool_name: pool_name} do
    result =
      VoiceASRProxy.forward(
        {:voice_asr, "AAAA"},
        %{
          principal_id: "ou_test",
          pool_name: pool_name,
          acquire_timeout: 200
        }
      )

    assert {:ok, "MOCK"} = result
  end

  test "capability denied short-circuits to {:drop, :cap_denied}", %{pool_name: pool_name} do
    Process.put(:esr_cap_test_override, fn _, _ -> false end)

    assert {:drop, :cap_denied} =
             VoiceASRProxy.forward({:voice_asr, "A"}, %{
               principal_id: "ou_test",
               pool_name: pool_name
             })
  end

  test "pool exhaustion returns {:drop, :pool_exhausted}" do
    # Exhausted pool: max=0 with a slow-enough acquire timeout so the
    # call short-circuits immediately.
    pool_name = :"vasr_exhausted_#{:erlang.unique_integer([:positive])}"
    {:ok, _pool} = Esr.Entity.Pool.start_link(name: pool_name, worker: DummyWorker, max: 1)

    # Fill the single slot.
    {:ok, _w} = Esr.Entity.Pool.acquire(pool_name)

    assert {:drop, :pool_exhausted} =
             VoiceASRProxy.forward({:voice_asr, "A"}, %{
               principal_id: "ou_test",
               pool_name: pool_name,
               acquire_timeout: 0
             })
  end
end

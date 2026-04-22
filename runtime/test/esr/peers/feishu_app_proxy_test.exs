defmodule Esr.Peers.FeishuAppProxyTest do
  @moduledoc """
  P3-8.3 — `FeishuAppProxy` declares `@required_cap "peer_proxy:feishu/forward"`
  (canonical `prefix:name/perm` form; see
  `docs/notes/capability-name-format-mismatch.md`). The Peer.Proxy macro
  wraps `forward/2` with a capability check that consults
  `Esr.Capabilities.has?/2` in production and the
  `:esr_cap_test_override` process-dict key under test. This file covers
  both paths: the override-based unit cases (fast, local to the proxy
  macro behaviour) and one integration-style case using the real
  `Grants.load_snapshot/1` flow to prove the canonical form actually
  passes `Grants.matches?/2`.
  """
  use ExUnit.Case, async: false

  alias Esr.Capabilities.Grants
  alias Esr.Peers.FeishuAppProxy

  test "forward/2 calls Capabilities.has? before dispatching to target" do
    # FeishuAppProxy declares @required_cap "peer_proxy:feishu/forward"
    Process.put(:esr_cap_test_override, fn
      "p_allowed", "peer_proxy:feishu/forward" -> true
      _, _ -> false
    end)

    target = self()
    ctx = %{principal_id: "p_allowed", target_pid: target, app_id: "cli_app_x"}
    assert :ok = FeishuAppProxy.forward({:outbound, %{"hello" => 1}}, ctx)
    assert_receive {:outbound, %{"hello" => 1}}, 100
  after
    Process.delete(:esr_cap_test_override)
  end

  test "forward/2 returns {:drop, :cap_denied} when capability missing" do
    Process.put(:esr_cap_test_override, fn _, _ -> false end)

    ctx = %{principal_id: "p_denied", target_pid: self(), app_id: "cli_app_x"}
    assert {:drop, :cap_denied} = FeishuAppProxy.forward({:outbound, %{}}, ctx)
    refute_receive _, 50
  after
    Process.delete(:esr_cap_test_override)
  end

  test "forward/2 returns {:drop, :target_unavailable} when target_pid is dead" do
    Process.put(:esr_cap_test_override, fn _, _ -> true end)

    # Spawn and immediately kill.
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, _, _, _}, 100

    ctx = %{principal_id: "p", target_pid: dead, app_id: "cli_app_x"}
    assert {:drop, :target_unavailable} = FeishuAppProxy.forward({:outbound, %{}}, ctx)
  after
    Process.delete(:esr_cap_test_override)
  end

  describe "real-Grants integration (P3-8.3 canonical form check)" do
    setup do
      prior =
        try do
          :ets.tab2list(:esr_capabilities_grants) |> Map.new()
        rescue
          _ -> %{}
        end

      on_exit(fn -> Grants.load_snapshot(prior) end)
      :ok
    end

    test "real Grants accepts peer_proxy:feishu/forward via canonical format" do
      Grants.load_snapshot(%{"ou_alice" => ["peer_proxy:feishu/forward"]})

      ctx = %{principal_id: "ou_alice", target_pid: self(), app_id: "cli_app_x"}
      assert :ok = FeishuAppProxy.forward({:outbound, %{"hello" => 1}}, ctx)
      assert_receive {:outbound, %{"hello" => 1}}, 100
    end

    test "real Grants rejects principal without the cap" do
      Grants.load_snapshot(%{"ou_nope" => []})

      ctx = %{principal_id: "ou_nope", target_pid: self(), app_id: "cli_app_x"}
      assert {:drop, :cap_denied} = FeishuAppProxy.forward({:outbound, %{}}, ctx)
      refute_receive _, 50
    end
  end
end

defmodule Esr.Peers.FeishuAppProxyTest do
  use ExUnit.Case, async: false

  alias Esr.Peers.FeishuAppProxy

  test "forward/2 calls Capabilities.has? before dispatching to target" do
    # FeishuAppProxy declares @required_cap "cap.peer_proxy.forward_feishu"
    Process.put(:esr_cap_test_override, fn
      "p_allowed", "cap.peer_proxy.forward_feishu" -> true
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
end

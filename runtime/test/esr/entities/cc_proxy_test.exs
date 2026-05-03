defmodule Esr.Entities.CCProxyTest do
  @moduledoc """
  P3-1.1 — `CCProxy` is a stateless Peer.Proxy that forwards messages from
  FeishuChatProxy (upstream) to the local CCProcess (downstream) within the
  same Session. The `@required_cap "peer_proxy:cc/forward"` attribute (canonical
  `prefix:name/perm` form per P3-8) wires the Peer.Proxy macro to run a
  capability check via `Esr.Capabilities.has?/2` before dispatch. In PR-3
  this is a pure forwarder; the cap hook is the first rate-limit / throttle
  enforcement point between channels and CC agents.

  These tests cover the forward happy-path, dead-target drop, and
  capability-denied drop paths. Cap-check uses the real `Grants` snapshot
  rather than the process-dict override so the canonical-name form is
  validated end-to-end against `Grants.matches?/2`.

  Spec §3.6, §4.1 CCProxy card; expansion P3-1.1.
  """
  use ExUnit.Case, async: false

  alias Esr.Capabilities.Grants
  alias Esr.Entities.CCProxy

  setup do
    prior =
      try do
        :ets.tab2list(:esr_capabilities_grants) |> Map.new()
      rescue
        _ -> %{}
      end

    Grants.load_snapshot(%{"ou_alice" => ["peer_proxy:cc/forward"]})
    on_exit(fn -> Grants.load_snapshot(prior) end)
    :ok
  end

  test "forward/2 sends msg to cc_process_pid when alive" do
    me = self()
    fake_cc = spawn_link(fn -> receive_loop(me) end)
    ctx = %{principal_id: "ou_alice", cc_process_pid: fake_cc}

    assert :ok = CCProxy.forward({:text, "hello"}, ctx)
    assert_receive {:forwarded, {:text, "hello"}}, 200
  end

  test "forward/2 drops :target_unavailable when cc_process_pid is dead" do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, _, _, _}, 200
    refute Process.alive?(dead)
    ctx = %{principal_id: "ou_alice", cc_process_pid: dead}

    assert {:drop, :target_unavailable} = CCProxy.forward({:text, "x"}, ctx)
  end

  test "forward/2 drops :cap_denied when principal lacks the canonical cap" do
    Grants.load_snapshot(%{"ou_bob" => []})
    me = self()
    fake_cc = spawn_link(fn -> receive_loop(me) end)
    ctx = %{principal_id: "ou_bob", cc_process_pid: fake_cc}

    assert {:drop, :cap_denied} = CCProxy.forward({:text, "x"}, ctx)
    refute_receive {:forwarded, _}, 50
  end

  test "forward/2 drops :cap_denied when principal_id is missing from ctx" do
    me = self()
    fake_cc = spawn_link(fn -> receive_loop(me) end)
    ctx = %{cc_process_pid: fake_cc}

    assert {:drop, :cap_denied} = CCProxy.forward({:text, "x"}, ctx)
    refute_receive {:forwarded, _}, 50
  end

  test "forward/2 drops :invalid_ctx when cc_process_pid is absent (cap allowed)" do
    ctx = %{principal_id: "ou_alice"}
    assert {:drop, :invalid_ctx} = CCProxy.forward({:text, "x"}, ctx)
  end

  defp receive_loop(reply_to) do
    receive do
      msg ->
        send(reply_to, {:forwarded, msg})
        receive_loop(reply_to)
    end
  end
end

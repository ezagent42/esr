defmodule Esr.Peers.FeishuAppAdapterDenyDmTest do
  @moduledoc """
  Drop-Lane-A T1.3 — FAA-side deny-DM dispatch (Elixir-only auth flow).

  When `Esr.PeerServer`'s Lane B inbound gate denies a Feishu inbound
  envelope (capabilities spec §7.2), it now sends `{:dispatch_deny_dm,
  principal_id, chat_id}` to the source app's FAA peer (resolved via
  `Esr.PeerRegistry` keyed by `"feishu_app_adapter_<instance_id>"`).
  This module exercises FAA's handling of that message:

   * first emission within a fresh window dispatches an outbound
     `{:outbound, %{"kind" => "reply", ...}}` directive carrying the
     Chinese deny text — which routes through FAA's existing
     `handle_downstream` clause and lands as an `adapter:feishu/<id>`
     PubSub broadcast that the Python adapter consumes.
   * second emission within 10 min for the same principal is suppressed
     (rate-limit lives in FAA state, per-(principal, instance_id)).
   * different principals don't share the rate-limit window.
   * after the 10 min window elapses, a fresh emission fires.
   * empty/missing principal_id is dropped (no DM, no GenServer crash).

  Spec: docs/superpowers/specs/2026-04-25-drop-lane-a-auth.md §Task 1.3.
  """

  use ExUnit.Case, async: false

  alias Esr.Peers.FeishuAppAdapter

  @deny_dm_text "你无权使用此 bot，请联系管理员授权。"

  setup do
    # Same pattern as feishu_app_adapter_test.exs: rely on app-level
    # SessionRegistry / AdminSessionProcess; spin up a per-test
    # DynamicSupervisor so child FAAs are isolated and torn down on
    # exit. The test pid subscribes to the FAA's outbound PubSub topic
    # so we can assert the directive shape.
    assert is_pid(Process.whereis(Esr.SessionRegistry))
    assert is_pid(Process.whereis(Esr.AdminSessionProcess))

    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    on_exit(fn -> if Process.alive?(sup), do: Process.exit(sup, :shutdown) end)

    instance_id = "denydm_#{System.unique_integer([:positive])}"

    {:ok, faa_pid} =
      DynamicSupervisor.start_child(
        sup,
        {FeishuAppAdapter, %{instance_id: instance_id, neighbors: [], proxy_ctx: %{}}}
      )

    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "adapter:feishu/#{instance_id}")

    {:ok, sup: sup, faa: faa_pid, instance_id: instance_id}
  end

  test "first dispatch emits an outbound directive with the deny text", %{faa: faa} do
    send(faa, {:dispatch_deny_dm, "ou_stranger", "oc_chat_1"})

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "envelope",
                     payload: %{
                       "kind" => "directive",
                       "payload" => %{
                         "adapter" => "feishu",
                         "action" => "send_message",
                         "args" => %{"chat_id" => "oc_chat_1", "content" => @deny_dm_text}
                       }
                     }
                   },
                   500
  end

  test "second dispatch within 10 min for the same principal is suppressed", %{faa: faa} do
    send(faa, {:dispatch_deny_dm, "ou_stranger", "oc_chat_1"})

    assert_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 500

    # Second dispatch — same principal, same chat. Should be rate-limited.
    send(faa, {:dispatch_deny_dm, "ou_stranger", "oc_chat_1"})

    refute_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 200
  end

  test "dispatch for different principals don't share the rate-limit", %{faa: faa} do
    send(faa, {:dispatch_deny_dm, "ou_stranger_a", "oc_chat_1"})
    assert_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 500

    # A different principal id resets rate-limit semantics — even within
    # the same 10-min window we expect a fresh emission.
    send(faa, {:dispatch_deny_dm, "ou_stranger_b", "oc_chat_1"})
    assert_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 500
  end

  test "dispatch after the 10 min window elapses emits again", %{faa: faa} do
    # First emission seeds the rate-limit map.
    send(faa, {:dispatch_deny_dm, "ou_stranger", "oc_chat_1"})
    assert_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 500

    # Manually rewind the rate-limit timestamp to just past the window.
    # We use :sys.replace_state so we don't have to wait 10 real minutes
    # — the FAA reads the map via :erlang.monotonic_time(:millisecond)
    # so any value from the past in monotonic_ms units is enough.
    past = :erlang.monotonic_time(:millisecond) - 11 * 60 * 1000

    :sys.replace_state(faa, fn state ->
      Map.put(state, :deny_dm_last_emit, %{"ou_stranger" => past})
    end)

    send(faa, {:dispatch_deny_dm, "ou_stranger", "oc_chat_1"})
    assert_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 500
  end

  test "dispatch with empty/missing principal_id is dropped (no DM, no crash)", %{faa: faa} do
    # Empty string principal_id — the regex match in peer_server.ex
    # would also reject this, but we belt-and-braces it inside FAA so
    # an internally-fired bad dispatch can't crash the GenServer.
    send(faa, {:dispatch_deny_dm, "", "oc_chat_1"})
    refute_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 200
    assert Process.alive?(faa)

    # `nil` principal_id — same expectation.
    send(faa, {:dispatch_deny_dm, nil, "oc_chat_1"})
    refute_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 200
    assert Process.alive?(faa)
  end
end

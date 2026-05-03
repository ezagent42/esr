defmodule Esr.Entities.CapGuardDenyDmTest do
  @moduledoc """
  PR-21x — `Esr.Entities.CapGuard` owns Lane B deny-DM rate-limit and
  dispatch. On deny it sends `{:outbound, %{"kind" => "reply", ...}}`
  directly to the source app's FAA peer; FAA's existing
  `handle_downstream/2` wraps it as a directive on
  `adapter:feishu/<instance_id>` (the same wire shape the Python
  adapter consumes).

  Cases (mirroring the pre-PR-21x FAA-side test):
   * first deny within a fresh window emits the directive
   * second deny within 10 min for the same principal is suppressed
   * different principals don't share the rate-limit window
   * rewinding the rate-limit timestamp lets a fresh emission fire
   * empty/missing principal_id is dropped (no DM, no crash)

  Original spec: docs/superpowers/specs/2026-04-25-drop-lane-a-auth.md §Task 1.3.
  """

  use ExUnit.Case, async: false

  alias Esr.Capabilities.Grants
  alias Esr.Entities.{CapGuard, FeishuAppAdapter}
  alias Esr.TestSupport.AuthContext

  @deny_dm_text "你无权使用此 bot，请联系管理员授权。"

  setup do
    Grants.load_snapshot(%{})
    AuthContext.load(%{})

    if pid = Process.whereis(CapGuard) do
      :sys.replace_state(pid, fn state -> %{state | last_emit: %{}} end)
    end

    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    on_exit(fn -> if Process.alive?(sup), do: Process.exit(sup, :shutdown) end)

    instance_id = "denydm_#{System.unique_integer([:positive])}"

    {:ok, _faa_pid} =
      DynamicSupervisor.start_child(
        sup,
        {FeishuAppAdapter, %{instance_id: instance_id, neighbors: [], proxy_ctx: %{}}}
      )

    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "adapter:feishu/#{instance_id}")

    {:ok, sup: sup, instance_id: instance_id}
  end

  defp deny_envelope(instance_id, principal_id, chat_id) do
    %{
      "principal_id" => principal_id,
      "workspace_name" => "proj-a",
      "source" => "esr://localhost/adapters/feishu/#{instance_id}",
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{"chat_id" => chat_id}
      }
    }
  end

  test "first deny emits an outbound directive with the deny text",
       %{instance_id: instance_id} do
    envelope = deny_envelope(instance_id, "ou_stranger", "oc_chat_1")
    assert :denied = CapGuard.check_inbound(envelope, "workspace:proj-a/msg.send", "actor-1")

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

  test "second deny within 10 min for the same principal is suppressed",
       %{instance_id: instance_id} do
    envelope = deny_envelope(instance_id, "ou_stranger", "oc_chat_1")
    :denied = CapGuard.check_inbound(envelope, "workspace:proj-a/msg.send", "actor-1")
    assert_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 500

    :denied = CapGuard.check_inbound(envelope, "workspace:proj-a/msg.send", "actor-1")
    refute_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 200
  end

  test "different principals don't share the rate-limit",
       %{instance_id: instance_id} do
    env_a = deny_envelope(instance_id, "ou_stranger_a", "oc_chat_1")
    :denied = CapGuard.check_inbound(env_a, "workspace:proj-a/msg.send", "actor-1")
    assert_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 500

    env_b = deny_envelope(instance_id, "ou_stranger_b", "oc_chat_1")
    :denied = CapGuard.check_inbound(env_b, "workspace:proj-a/msg.send", "actor-1")
    assert_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 500
  end

  test "deny after the 10 min window elapses emits again",
       %{instance_id: instance_id} do
    envelope = deny_envelope(instance_id, "ou_stranger", "oc_chat_1")
    :denied = CapGuard.check_inbound(envelope, "workspace:proj-a/msg.send", "actor-1")
    assert_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 500

    past = :erlang.monotonic_time(:millisecond) - 11 * 60 * 1000

    :sys.replace_state(Process.whereis(CapGuard), fn state ->
      %{state | last_emit: %{"ou_stranger" => past}}
    end)

    :denied = CapGuard.check_inbound(envelope, "workspace:proj-a/msg.send", "actor-1")
    assert_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 500
  end

  test "deny with empty principal_id emits no DM and doesn't crash",
       %{instance_id: instance_id} do
    env_empty = deny_envelope(instance_id, "", "oc_chat_1")
    :denied = CapGuard.check_inbound(env_empty, "workspace:proj-a/msg.send", "actor-1")
    refute_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 200

    env_nil = %{
      "principal_id" => nil,
      "workspace_name" => "proj-a",
      "source" => "esr://localhost/adapters/feishu/#{instance_id}",
      "payload" => %{"event_type" => "msg_received", "args" => %{"chat_id" => "oc_chat_1"}}
    }

    :denied = CapGuard.check_inbound(env_nil, "workspace:proj-a/msg.send", "actor-1")
    refute_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 200

    assert Process.alive?(Process.whereis(CapGuard))
  end
end

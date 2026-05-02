defmodule Esr.PeerServerLaneBDenyDispatchTest do
  @moduledoc """
  PR-21x — Lane B deny path now dispatches an
  `{:outbound, %{"kind" => "reply", ...}}` message to the source app's
  FAA peer (resolved via `Esr.PeerRegistry` keyed by
  `"feishu_app_adapter_<instance_id>"`). Cap check + rate-limit live
  in `Esr.Peers.CapGuard`; FAA's existing `handle_downstream/2`
  wraps the outbound into a directive on `adapter:feishu/<id>`.

  Three cases:
   1. Deny path with a Feishu-source envelope sends the outbound to
      the registered FAA pid.
   2. Allow path doesn't send anything to FAA.
   3. Deny path with no FAA registered (or non-Feishu source) logs
      a warning and doesn't crash.

  We don't stand up a real FAA here — instead we register the test
  process in `Esr.PeerRegistry` under the expected key, then assert
  the message lands. CapGuard rate-limit / FAA directive-wrap covered
  by separate tests.

  Original spec: docs/superpowers/specs/2026-04-25-drop-lane-a-auth.md §Task 1.4.
  """

  use ExUnit.Case, async: false

  alias Esr.Capabilities.Grants
  alias Esr.PeerServer
  alias Esr.TestSupport.AuthContext

  @deny_dm_text "你无权使用此 bot，请联系管理员授权。"

  setup do
    Grants.load_snapshot(%{})
    # PR-21x: reset CapGuard rate-limit between tests so a fresh
    # principal_id always passes the rate-limit gate.
    if pid = Process.whereis(Esr.Peers.CapGuard) do
      :sys.replace_state(pid, fn state -> %{state | last_emit: %{}} end)
    end

    :ok
  end

  defp start_peer(actor_id) do
    {:ok, pid} =
      start_supervised(
        {PeerServer,
         [
           actor_id: actor_id,
           actor_type: "test_actor",
           handler_module: "noop",
           initial_state: %{},
           handler_timeout: 200
         ]}
      )

    pid
  end

  defp register_fake_faa(instance_id) do
    # PeerRegistry.register only registers the calling pid (see its
    # moduledoc). To register the test process, we just call it from
    # here — `self()` is the test pid.
    :ok =
      case Esr.PeerRegistry.register("feishu_app_adapter_#{instance_id}", self()) do
        {:ok, _} -> :ok
        # Already registered from a previous test crashing mid-flight.
        # Registry entries are reaped when their owner dies, so this
        # shouldn't happen across runs — but belt-and-braces.
        {:error, {:already_registered, _}} -> :ok
      end

    on_exit(fn -> Registry.unregister(Esr.PeerRegistry, "feishu_app_adapter_#{instance_id}") end)
    :ok
  end

  test "deny path sends {:outbound, _} to the resolved FAA pid" do
    AuthContext.load(%{"ou_stranger" => []})

    instance_id = "deny_dispatch_#{System.unique_integer([:positive])}"
    register_fake_faa(instance_id)

    actor_id = "lane-b-deny-dispatch-#{System.unique_integer([:positive])}"
    peer_pid = start_peer(actor_id)

    envelope = %{
      "id" => "e-deny-1",
      "principal_id" => "ou_stranger",
      "workspace_name" => "proj-a",
      "source" => "esr://localhost/adapters/feishu/#{instance_id}",
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{"chat_id" => "oc_chat_1"}
      }
    }

    send(peer_pid, {:inbound_event, envelope})

    assert_receive {:outbound,
                    %{
                      "kind" => "reply",
                      "args" => %{"chat_id" => "oc_chat_1", "text" => @deny_dm_text}
                    }},
                   500
  end

  test "allow path doesn't send {:outbound, _} to FAA" do
    # Grant the principal so the inbound passes the gate.
    AuthContext.load(%{"ou_ok" => ["workspace:proj-a/msg.send"]})

    instance_id = "deny_dispatch_allow_#{System.unique_integer([:positive])}"
    register_fake_faa(instance_id)

    actor_id = "lane-b-allow-dispatch-#{System.unique_integer([:positive])}"
    peer_pid = start_peer(actor_id)

    envelope = %{
      "id" => "e-allow-1",
      "principal_id" => "ou_ok",
      "workspace_name" => "proj-a",
      "source" => "esr://localhost/adapters/feishu/#{instance_id}",
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{"chat_id" => "oc_chat_1"}
      }
    }

    send(peer_pid, {:inbound_event, envelope})

    # The allow path then calls the handler; with handler_timeout=200
    # and no fake worker, the handler-router call times out and emits
    # an [:esr, :handler, :error] (which we don't care about). What we
    # DO care about: no deny-DM outbound hits the test pid.
    refute_receive {:outbound, _}, 400
  end

  test "deny path with no FAA registered logs a warning and doesn't crash" do
    AuthContext.load(%{"ou_stranger" => []})

    # Deliberately do NOT register a fake FAA. The instance_id in the
    # source URI is unique and won't resolve in PeerRegistry.
    instance_id = "deny_dispatch_no_faa_#{System.unique_integer([:positive])}"

    actor_id = "lane-b-deny-no-faa-#{System.unique_integer([:positive])}"
    peer_pid = start_peer(actor_id)

    envelope = %{
      "id" => "e-deny-no-faa",
      "principal_id" => "ou_stranger",
      "workspace_name" => "proj-a",
      "source" => "esr://localhost/adapters/feishu/#{instance_id}",
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{"chat_id" => "oc_chat_1"}
      }
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(peer_pid, {:inbound_event, envelope})
        # Give the GenServer a moment to process before we sample logs.
        Process.sleep(50)
      end)

    assert log =~ "CapGuard Lane B deny"
    assert log =~ instance_id
    assert Process.alive?(peer_pid)
  end

  test "deny path with non-Feishu source doesn't attempt FAA dispatch and doesn't crash" do
    AuthContext.load(%{"ou_stranger" => []})

    actor_id = "lane-b-deny-non-feishu-#{System.unique_integer([:positive])}"
    peer_pid = start_peer(actor_id)

    # Non-feishu source — the regex ^esr://[^/]+/adapters/feishu/([^/]+)$
    # must NOT match, dispatch_deny_dm/1 returns :ok without lookup.
    envelope = %{
      "id" => "e-deny-non-feishu",
      "principal_id" => "ou_stranger",
      "workspace_name" => "proj-a",
      "source" => "esr://localhost/adapters/cc_mcp/some_id",
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{"chat_id" => "oc_chat_1"}
      }
    }

    send(peer_pid, {:inbound_event, envelope})

    # No FAA outbound should leak to the test pid even though no FAA
    # is registered for this source — the regex guard short-circuits
    # before any registry lookup.
    refute_receive {:outbound, _}, 200
    assert Process.alive?(peer_pid)
  end
end

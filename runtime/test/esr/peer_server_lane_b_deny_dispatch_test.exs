defmodule Esr.PeerServerLaneBDenyDispatchTest do
  @moduledoc """
  Drop-Lane-A T1.4 — peer_server.ex deny path now dispatches a
  `{:dispatch_deny_dm, principal_id, chat_id}` directive to the
  source app's FAA peer (resolved via `Esr.PeerRegistry` keyed by
  `"feishu_app_adapter_<instance_id>"`).

  Three cases:
   1. Deny path with a Feishu-source envelope sends the dispatch to
      the registered FAA pid.
   2. Allow path doesn't send anything to FAA.
   3. Deny path with no FAA registered (or non-Feishu source) logs
      a warning and doesn't crash.

  We don't stand up a real FAA here — instead we register the test
  process in `Esr.PeerRegistry` under the expected key, then assert
  the message lands. This isolates the wiring without depending on
  FAA-side behaviour (covered separately in
  `feishu_app_adapter_deny_dm_test.exs`).

  Spec: docs/superpowers/specs/2026-04-25-drop-lane-a-auth.md §Task 1.4.
  """

  use ExUnit.Case, async: false

  alias Esr.Capabilities.Grants
  alias Esr.PeerServer
  alias Esr.TestSupport.AuthContext

  setup do
    Grants.load_snapshot(%{})
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

  test "deny path sends {:dispatch_deny_dm, _, _} to the resolved FAA pid" do
    AuthContext.load(%{"ou_stranger" => []})

    instance_id = "deny_dispatch_#{System.unique_integer([:positive])}"
    register_fake_faa(instance_id)

    actor_id = "lane-b-deny-dispatch-#{System.unique_integer([:positive])}"
    peer_pid = start_peer(actor_id)

    envelope = %{
      "id" => "e-deny-1",
      "principal_id" => "ou_stranger",
      "workspace_name" => "proj-a",
      "source" => "esr://localhost/adapter:feishu/#{instance_id}",
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{"chat_id" => "oc_chat_1"}
      }
    }

    send(peer_pid, {:inbound_event, envelope})

    assert_receive {:dispatch_deny_dm, "ou_stranger", "oc_chat_1"}, 500
  end

  test "allow path doesn't send {:dispatch_deny_dm, _, _} to FAA" do
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
      "source" => "esr://localhost/adapter:feishu/#{instance_id}",
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{"chat_id" => "oc_chat_1"}
      }
    }

    send(peer_pid, {:inbound_event, envelope})

    # The allow path then calls the handler; with handler_timeout=200
    # and no fake worker, the handler-router call times out and emits
    # an [:esr, :handler, :error] (which we don't care about). What we
    # DO care about: no deny-DM dispatch hits the test pid.
    refute_receive {:dispatch_deny_dm, _, _}, 400
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
      "source" => "esr://localhost/adapter:feishu/#{instance_id}",
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

    assert log =~ "Lane B deny"
    assert log =~ instance_id
    assert Process.alive?(peer_pid)
  end

  test "deny path with non-Feishu source doesn't attempt FAA dispatch and doesn't crash" do
    AuthContext.load(%{"ou_stranger" => []})

    actor_id = "lane-b-deny-non-feishu-#{System.unique_integer([:positive])}"
    peer_pid = start_peer(actor_id)

    # cc_tmux source — the regex ^esr://[^/]+/adapter:feishu/([^/]+)$
    # must NOT match, dispatch_deny_dm/1 returns :ok without lookup.
    envelope = %{
      "id" => "e-deny-non-feishu",
      "principal_id" => "ou_stranger",
      "workspace_name" => "proj-a",
      "source" => "esr://localhost/adapter:cc_tmux/some_id",
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{"chat_id" => "oc_chat_1"}
      }
    }

    send(peer_pid, {:inbound_event, envelope})

    # No FAA dispatch should leak to the test pid even though no FAA
    # is registered for this source — the regex guard short-circuits
    # before any registry lookup.
    refute_receive {:dispatch_deny_dm, _, _}, 200
    assert Process.alive?(peer_pid)
  end
end

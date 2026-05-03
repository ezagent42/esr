defmodule Esr.EntityServerLaneBTest do
  @moduledoc """
  Capabilities spec §7.2 / §7.3 (CAP-4) — Lane B enforcement.

  `Esr.Entity.Server` checks the caller's grants before dispatching
  `{:inbound_event, ...}` to the handler and before dispatching
  `{:tool_invoke, ..., principal_id}` to the real adapter. Denied
  calls emit `[:esr, :capabilities, :denied]` telemetry with
  `lane: :B_inbound` or `lane: :B_tool_invoke`.

  The `Esr.Capabilities.Grants` ETS singleton is started by
  `Esr.Application` — we just load per-test snapshots on top.
  """

  use ExUnit.Case, async: false

  alias Esr.Capabilities.Grants
  alias Esr.Entity
  alias Esr.TestSupport.AuthContext

  setup do
    # Reset grants so each test starts with an empty snapshot. Tests
    # that want a grant load it explicitly.
    Grants.load_snapshot(%{})
    :ok
  end

  defp start_peer(actor_id, overrides \\ []) do
    opts =
      [
        actor_id: actor_id,
        actor_type: "test_actor",
        handler_module: "noop",
        initial_state: %{},
        handler_timeout: 200
      ]
      |> Keyword.merge(overrides)

    {:ok, pid} = start_supervised({Entity.Server, opts})
    pid
  end

  # Attach an ad-hoc telemetry listener that forwards the given event
  # to the calling test process, returns the handler id for detach.
  defp attach_denied(tag) do
    id = "lane-b-denied-#{tag}-#{:erlang.unique_integer()}"
    test_pid = self()

    :telemetry.attach(
      id,
      [:esr, :capabilities, :denied],
      fn _event, _measurements, metadata, pid ->
        send(pid, {:denied, metadata})
      end,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(id) end)
    id
  end

  # Simulates a Python handler worker: replies with an empty new_state
  # and no actions. Only attached for the "handler IS invoked" cases.
  defp start_fake_worker do
    topic = "handler:noop/default"
    test_pid = self()

    Task.async(fn ->
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, topic)
      send(test_pid, :worker_ready)
      fake_worker_loop(test_pid)
    end)
  end

  defp fake_worker_loop(test_pid) do
    receive do
      %Phoenix.Socket.Broadcast{event: "envelope", payload: env} ->
        Phoenix.PubSub.broadcast(
          EsrWeb.PubSub,
          "handler_reply:" <> env["id"],
          {:handler_reply, %{"id" => env["id"], "payload" => %{"new_state" => %{}, "actions" => []}}}
        )

        send(test_pid, {:handler_called, env})
        fake_worker_loop(test_pid)

      :stop ->
        :ok
    after
      2_000 -> :timeout
    end
  end

  # --------------------------------------------------------------
  # inbound_event lane
  # --------------------------------------------------------------

  test "inbound_event without matching capability denies + emits telemetry" do
    attach_denied("inbound-deny")
    AuthContext.load(%{"ou_unauth" => []})

    actor_id = "lane-b-deny-#{System.unique_integer([:positive])}"
    peer_pid = start_peer(actor_id)

    # No fake worker — if the check DID pass, HandlerRouter.call would
    # time out (200ms) and [:esr, :handler, :error] would fire. Our
    # assertion is that [:esr, :capabilities, :denied] fires FIRST.

    envelope = %{
      "id" => "e-deny-1",
      "principal_id" => "ou_unauth",
      "workspace_name" => "proj-a",
      "payload" => %{"event_type" => "msg_received", "args" => %{}}
    }

    send(peer_pid, {:inbound_event, envelope})

    assert_receive {:denied, metadata}, 500
    assert metadata.principal_id == "ou_unauth"
    assert metadata.required_perm == "workspace:proj-a/msg.send"
    assert metadata.lane == :B_inbound
  end

  test "inbound_event with msg.send grant invokes handler" do
    AuthContext.load(%{"ou_ok" => ["workspace:proj-a/msg.send"]})

    worker = start_fake_worker()
    assert_receive :worker_ready, 500

    actor_id = "lane-b-allow-#{System.unique_integer([:positive])}"
    peer_pid = start_peer(actor_id)

    envelope = %{
      "id" => "e-ok-1",
      "principal_id" => "ou_ok",
      "workspace_name" => "proj-a",
      "payload" => %{"event_type" => "msg_received", "args" => %{}}
    }

    send(peer_pid, {:inbound_event, envelope})

    assert_receive {:handler_called, _env}, 1_000

    send(worker.pid, :stop)
  end

  # --------------------------------------------------------------
  # tool_invoke lane
  # --------------------------------------------------------------

  test "tool_invoke without capability replies unauthorized; no emit" do
    attach_denied("tool-deny")
    AuthContext.load(%{"ou_user" => ["workspace:proj-a/msg.send"]})

    actor_id = "lane-b-tool-deny-#{System.unique_integer([:positive])}"
    peer_pid = start_peer(actor_id)

    # Subscribe to the emit topic that emit_and_track would broadcast
    # to — we assert this receives NOTHING for a denied invoke.
    emit_topic = "adapter:feishu/" <> actor_id
    EsrWeb.Endpoint.subscribe(emit_topic)

    req_id = "r-deny-1"

    send(peer_pid, {
      :tool_invoke,
      req_id,
      "session.create",
      %{"workspace_name" => "proj-a"},
      self(),
      "ou_user"
    })

    assert_receive {:tool_result, ^req_id, result}, 500
    assert result["ok"] == false
    assert result["error"]["type"] == "unauthorized"
    assert result["error"]["required_perm"] == "workspace:proj-a/session.create"

    assert_receive {:denied, metadata}, 100
    assert metadata.principal_id == "ou_user"
    assert metadata.required_perm == "workspace:proj-a/session.create"
    assert metadata.lane == :B_tool_invoke

    # No directive broadcast should have gone out.
    refute_receive %Phoenix.Socket.Broadcast{event: "envelope"}, 200
  end

  test "admin wildcard bypasses both inbound_event and tool_invoke" do
    AuthContext.load_admin("ou_admin")

    worker = start_fake_worker()
    assert_receive :worker_ready, 500

    actor_id = "lane-b-admin-#{System.unique_integer([:positive])}"
    peer_pid = start_peer(actor_id, initial_state: %{"chat_id" => "oc_admin"})

    # inbound_event: handler IS invoked.
    envelope = %{
      "id" => "e-admin-1",
      "principal_id" => "ou_admin",
      "workspace_name" => "proj-a",
      "payload" => %{"event_type" => "msg_received", "args" => %{}}
    }

    send(peer_pid, {:inbound_event, envelope})
    assert_receive {:handler_called, _env}, 1_000

    # tool_invoke: emit is dispatched (we don't ack it — we just check
    # no {:tool_result, ..., unauthorized} comes back). Since the tool
    # "reply" is a known built-in, build_emit_for_tool/3 returns {:ok, _}
    # and emit_and_track subscribes + broadcasts. The :tool_result will
    # only arrive on ack or deadline — neither of which we're driving.
    req_id = "r-admin-1"
    emit_topic = "adapter:feishu/" <> actor_id
    EsrWeb.Endpoint.subscribe(emit_topic)

    send(peer_pid, {
      :tool_invoke,
      req_id,
      "reply",
      %{"chat_id" => "oc_admin", "text" => "hi", "workspace_name" => "proj-a"},
      self(),
      "ou_admin"
    })

    # Assert the emit broadcast DID fire (proving the capability check passed).
    assert_receive %Phoenix.Socket.Broadcast{event: "envelope", payload: env}, 1_000
    assert env["payload"]["action"] == "send_message"

    send(worker.pid, :stop)
  end
end

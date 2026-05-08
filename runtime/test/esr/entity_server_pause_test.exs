defmodule Esr.EntityServerPauseTest do
  @moduledoc """
  PRD 01 F20 — Pause / resume. Paused Entity.Server queues inbound_event
  messages in FIFO order; on resume they dispatch in arrival order
  before any further input. Emits `[:esr, :actor, :paused]` and
  `[:esr, :actor, :resumed]` telemetry.
  """

  use ExUnit.Case, async: false

  alias Esr.Entity
  alias Esr.TestSupport.AuthContext

  setup do
    for {actor_id, _pid} <- Esr.Entity.Registry.list_all() do
      Registry.unregister(Esr.Entity.Registry, actor_id)
    end

    # CAP-4 Lane B: drained events need a grant or the deny path fires
    # instead of retry_exhausted. Admin wildcard keeps the drain-order
    # assertion focused on FIFO behaviour, not permissions.
    AuthContext.load_admin("test_admin")

    :ok
  end

  defp spawn_peer(id) do
    {:ok, pid} =
      Entity.Server.start_link(
        actor_id: id,
        actor_type: "test_type",
        handler_module: "noop.handler",
        # Short timeout so invoke_handler fails fast without a Python worker.
        handler_timeout: 50,
        initial_state: %{}
      )

    pid
  end

  test "pause/1 emits [:esr, :actor, :paused] telemetry" do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "pause-test-#{:erlang.unique_integer()}",
      [:esr, :actor, :paused],
      fn _e, _m, metadata, _cfg -> send(test_pid, {ref, :paused, metadata}) end,
      nil
    )

    _pid = spawn_peer("pause:1")
    assert :ok = Entity.Server.pause("pause:1")

    assert_receive {^ref, :paused, %{actor_id: "pause:1"}}, 500
  end

  test "resume/1 emits [:esr, :actor, :resumed] telemetry" do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "resume-test-#{:erlang.unique_integer()}",
      [:esr, :actor, :resumed],
      fn _e, _m, metadata, _cfg -> send(test_pid, {ref, :resumed, metadata}) end,
      nil
    )

    _pid = spawn_peer("pause:2")
    :ok = Entity.Server.pause("pause:2")
    assert :ok = Entity.Server.resume("pause:2")

    assert_receive {^ref, :resumed, %{actor_id: "pause:2"}}, 500
  end

  test "inbound_event queues while paused and drains in FIFO order on resume" do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "pause-drain-#{:erlang.unique_integer()}",
      [:esr, :handler, :retry_exhausted],
      fn _e, _m, metadata, _cfg ->
        send(test_pid, {ref, :handler_error, metadata.event_id})
      end,
      nil
    )

    pid = spawn_peer("pause:3")

    :ok = Entity.Server.pause("pause:3")

    # Inject three events into the mailbox while paused. principal_id +
    # workspace_name satisfy the Lane B check — drained events are
    # expected to fail later at handler_timeout, not deny.
    for id <- ["e1", "e2", "e3"] do
      send(pid, {:inbound_event,
                 %{"id" => id,
                   "principal_id" => "test_admin",
                   "workspace_name" => "test-ws",
                   "payload" => %{}}})
    end

    # Pending queue holds them in FIFO order.
    assert Entity.Server.pending_count("pause:3") == 3

    :ok = Entity.Server.resume("pause:3")

    # Handler call times out (no Python worker); each queued event emits
    # [:esr, :handler, :error] with its event_id — we observe the FIFO
    # order via the received messages.
    assert_receive {^ref, :handler_error, "e1"}, 1_000
    assert_receive {^ref, :handler_error, "e2"}, 1_000
    assert_receive {^ref, :handler_error, "e3"}, 1_000

    # Queue is now empty.
    assert Entity.Server.pending_count("pause:3") == 0
  end
end

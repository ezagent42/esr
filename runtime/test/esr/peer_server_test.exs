defmodule Esr.PeerServerTest do
  @moduledoc """
  PRD 01 F05 — PeerServer skeleton. Verifies initial state is stored
  and retrievable; registers itself in PeerRegistry; emits the
  `[:esr, :actor, :spawned]` telemetry event on init.

  Event handling (F06), action dispatch (F07), pause/resume (F20) come
  in later FRs.
  """

  use ExUnit.Case, async: false

  setup do
    for {actor_id, _pid} <- Esr.PeerRegistry.list_all() do
      Registry.unregister(Esr.PeerRegistry, actor_id)
    end

    :ok
  end

  describe "start_link/1" do
    test "starts a PeerServer and registers it in PeerRegistry" do
      {:ok, pid} =
        Esr.PeerServer.start_link(
          actor_id: "test:1",
          actor_type: "test_type",
          handler_module: "noop.handler",
          initial_state: %{}
        )

      assert Process.alive?(pid)
      assert {:ok, ^pid} = Esr.PeerRegistry.lookup("test:1")
    end

    test "emits [:esr, :actor, :spawned] telemetry on init" do
      ref = make_ref()
      test_pid = self()

      handler = fn event, measurements, metadata, _config ->
        send(test_pid, {ref, event, measurements, metadata})
      end

      :telemetry.attach(
        "peer-server-test-#{:erlang.unique_integer()}",
        [:esr, :actor, :spawned],
        handler,
        nil
      )

      {:ok, _pid} =
        Esr.PeerServer.start_link(
          actor_id: "test:spawned",
          actor_type: "test_type",
          handler_module: "noop.handler",
          initial_state: %{}
        )

      assert_receive {^ref, [:esr, :actor, :spawned], _measurements, metadata}
      assert metadata.actor_id == "test:spawned"
      assert metadata.actor_type == "test_type"
    end
  end

  describe "get_state/1" do
    test "returns the initial_state after start" do
      {:ok, _pid} =
        Esr.PeerServer.start_link(
          actor_id: "test:state",
          actor_type: "test_type",
          handler_module: "noop.handler",
          initial_state: %{counter: 7}
        )

      assert Esr.PeerServer.get_state("test:state") == %{counter: 7}
    end
  end

  describe "trap_exit handling (S8)" do
    test "{:EXIT, _, _} info messages from non-parent pids don't produce unhandled-info warnings" do
      import ExUnit.CaptureLog

      {:ok, pid} =
        Esr.PeerServer.start_link(
          actor_id: "trap-exit-test-#{System.unique_integer([:positive])}",
          actor_type: "test_type",
          handler_module: "noop.handler",
          initial_state: %{}
        )

      # EXIT from the parent (the test process) is a stop signal to the
      # GenServer — send from a disposable pid instead so we exercise
      # the info-path clause.
      fake_from = spawn(fn -> :ok end)

      log =
        capture_log(fn ->
          send(pid, {:EXIT, fake_from, :normal})
          send(pid, {:EXIT, fake_from, :shutdown})
          Process.sleep(20)
        end)

      refute log =~ "unexpected"
      assert Process.alive?(pid)
    end
  end

  describe "dedup_keys bound (F05)" do
    test "dedup_keys is capped at 1000 entries with FIFO eviction" do
      handler = "dedup-bound-#{System.unique_integer([:positive])}"
      actor_id = "dedup-peer-#{System.unique_integer([:positive])}"

      # Fake worker that accepts everything.
      topic = "handler:" <> handler <> "/default"
      test_pid = self()

      Task.async(fn ->
        :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, topic)
        send(test_pid, :worker_ready)
        dedup_test_worker_loop()
      end)

      assert_receive :worker_ready, 500

      {:ok, pid} =
        Esr.PeerServer.start_link(
          actor_id: actor_id,
          actor_type: "dedup_bound",
          handler_module: handler,
          initial_state: %{},
          handler_timeout: 500
        )

      # Inject 1002 events with unique idempotency keys.
      for n <- 1..1002 do
        key = "k-#{n}"

        send(pid, {:inbound_event, %{
          "id" => "e-#{n}",
          "payload" => %{"args" => %{"idempotency_key" => key}}
        }})
      end

      # Wait briefly for the mailbox to drain.
      wait_until_dedup_size(pid, 1000, 200)

      state = :sys.get_state(pid)
      assert MapSet.size(state.dedup_keys) == 1000

      # Oldest keys evicted; newest kept.
      refute MapSet.member?(state.dedup_keys, "k-1")
      refute MapSet.member?(state.dedup_keys, "k-2")
      assert MapSet.member?(state.dedup_keys, "k-1001")
      assert MapSet.member?(state.dedup_keys, "k-1002")
    end
  end

  defp dedup_test_worker_loop do
    receive do
      %Phoenix.Socket.Broadcast{event: "handler_call", payload: env} ->
        Phoenix.PubSub.broadcast(
          EsrWeb.PubSub,
          "handler_reply:" <> env["id"],
          {:handler_reply,
           %{"id" => env["id"], "payload" => %{"new_state" => %{}, "actions" => []}}}
        )

        dedup_test_worker_loop()

      :stop ->
        :ok
    after
      10_000 -> :timeout
    end
  end

  defp wait_until_dedup_size(_pid, _target, 0), do: :ok

  defp wait_until_dedup_size(pid, target, attempts) do
    case :sys.get_state(pid) do
      %{dedup_keys: keys} ->
        if MapSet.size(keys) >= target do
          :ok
        else
          Process.sleep(20)
          wait_until_dedup_size(pid, target, attempts - 1)
        end
    end
  end
end

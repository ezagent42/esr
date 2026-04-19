defmodule Esr.PeerServerRetryTest do
  @moduledoc """
  PRD 01 F06 — On `{:error, :handler_timeout}` the PeerServer retries
  HandlerRouter.call once with a fresh attempt; on exhaustion it
  enqueues the event into `Esr.DeadLetter` and emits
  `[:esr, :handler, :retry_exhausted]`.
  """

  use ExUnit.Case, async: false

  alias Esr.PeerServer

  setup do
    Esr.DeadLetter.clear(Esr.DeadLetter)
    :ok
  end

  defp start_peer(actor_id, handler_module, opts \\ []) do
    {:ok, _} =
      start_supervised(
        {PeerServer,
         [
           actor_id: actor_id,
           actor_type: "test_actor",
           handler_module: handler_module,
           initial_state: %{},
           handler_timeout: 100
         ] ++ opts}
      )

    GenServer.whereis({:via, Registry, {Esr.PeerRegistry, actor_id}})
  end

  defp send_event(peer_pid, event_id) do
    send(peer_pid, {:inbound_event, %{
      "id" => event_id,
      "type" => "event",
      "source" => "esr://localhost/adapter/x",
      "payload" => %{"event_type" => "msg", "args" => %{}}
    }})
  end

  # Worker that ignores the first N handler_calls, replies to the rest.
  defp start_flaky_worker(handler_module, skip_first) do
    topic = "handler:" <> handler_module <> "/default"
    test_pid = self()

    Task.async(fn ->
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, topic)
      send(test_pid, :worker_ready)
      flaky_loop(skip_first)
    end)
  end

  defp flaky_loop(skip_remaining) do
    receive do
      %Phoenix.Socket.Broadcast{event: "envelope", payload: env} ->
        if skip_remaining > 0 do
          flaky_loop(skip_remaining - 1)
        else
          Phoenix.PubSub.broadcast(
            EsrWeb.PubSub,
            "handler_reply:" <> env["id"],
            {:handler_reply,
             %{"id" => env["id"], "payload" => %{"new_state" => %{}, "actions" => []}}}
          )

          flaky_loop(0)
        end

      :stop ->
        :ok
    after
      5_000 -> :timeout
    end
  end

  test "handler_timeout on first call → retry succeeds → [:esr, :handler, :invoked]" do
    handler = "retry-ok-#{System.unique_integer([:positive])}"
    actor_id = "retry-peer-1-#{System.unique_integer([:positive])}"

    _worker = start_flaky_worker(handler, 1)
    assert_receive :worker_ready, 500

    :telemetry.attach(
      "retry-invoked-#{:erlang.unique_integer()}",
      [:esr, :handler, :invoked],
      fn _e, _m, metadata, pid -> send(pid, {:invoked, metadata}) end,
      self()
    )

    peer_pid = start_peer(actor_id, handler)
    send_event(peer_pid, "e-retry-ok")

    # Should succeed on the 2nd attempt.
    assert_receive {:invoked, metadata}, 2_000
    assert metadata[:actor_id] == actor_id
    assert metadata[:event_id] == "e-retry-ok"
  end

  test "handler_timeout twice → [:esr, :handler, :retry_exhausted] + event lands in DeadLetter" do
    # No worker started — every call times out.
    handler = "retry-dead-#{System.unique_integer([:positive])}"
    actor_id = "retry-peer-2-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      "retry-exhausted-#{:erlang.unique_integer()}",
      [:esr, :handler, :retry_exhausted],
      fn _e, _m, metadata, pid -> send(pid, {:exhausted, metadata}) end,
      self()
    )

    peer_pid = start_peer(actor_id, handler)
    send_event(peer_pid, "e-dead")

    assert_receive {:exhausted, metadata}, 2_000
    assert metadata[:actor_id] == actor_id
    assert metadata[:event_id] == "e-dead"

    # DeadLetter captures the event for forensics.
    entries = Esr.DeadLetter.list(Esr.DeadLetter)
    assert Enum.any?(entries, fn e ->
             e.reason == :handler_retry_exhausted and e.source == actor_id
           end)
  end
end

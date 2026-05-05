defmodule Esr.Commands.DeadletterTest do
  @moduledoc """
  Unit coverage for `Esr.Commands.Deadletter.{List,Flush}`. Both
  modules wrap the live `Esr.Resource.DeadLetter.Queue` GenServer
  (started by the application supervisor), so tests clear the queue
  in setup and exercise `execute/1` directly.

  The yaml `e2e-feishu-cc.yaml` Track-H step that previously
  exercised these via `esr deadletter list` / `esr deadletter flush`
  was deleted alongside the rest of the v0.1 fossil scenarios in
  PR-223 — these tests are the replacement coverage.
  """
  use ExUnit.Case, async: false

  alias Esr.Resource.DeadLetter.Queue
  alias Esr.Commands.Deadletter

  setup do
    :ok = Queue.clear(Queue)
    on_exit(fn -> Queue.clear(Queue) end)
    :ok
  end

  describe "Deadletter.List.execute/1" do
    test "empty queue → human-readable empty marker" do
      assert {:ok, %{"text" => "no dead-letter entries"}} =
               Deadletter.List.execute(%{})
    end

    test "non-empty queue → JSON array of serialised entries" do
      :ok =
        Queue.enqueue(Queue, %{
          reason: :unknown_target,
          target: "ghost:42",
          msg: %{hello: "world"},
          source: "adapter:feishu/inst1",
          metadata: %{}
        })

      # enqueue is a cast; let it land.
      Process.sleep(20)

      assert {:ok, %{"text" => text}} = Deadletter.List.execute(%{})
      decoded = Jason.decode!(text)
      assert is_list(decoded)
      assert length(decoded) == 1
      [entry] = decoded
      assert entry["reason"] == "unknown_target"
      assert entry["target"] == "ghost:42"
      assert entry["source"] == "adapter:feishu/inst1"
    end
  end

  describe "Deadletter.Flush.execute/1" do
    test "empty queue → flushed 0 entries" do
      assert {:ok, %{"text" => "flushed 0 dead-letter entries"}} =
               Deadletter.Flush.execute(%{})
    end

    test "non-empty queue → reports count + leaves queue empty" do
      for i <- 1..3 do
        :ok =
          Queue.enqueue(Queue, %{
            reason: :test,
            target: "ghost:#{i}",
            msg: %{},
            source: "test"
          })
      end

      Process.sleep(20)

      assert {:ok, %{"text" => "flushed 3 dead-letter entries"}} =
               Deadletter.Flush.execute(%{})

      assert Queue.list(Queue) == []
    end
  end
end

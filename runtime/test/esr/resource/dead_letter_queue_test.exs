defmodule Esr.DeadLetterTest do
  @moduledoc """
  PRD 01 F19 — bounded FIFO dead-letter queue. Stores events that
  failed to route; queryable and bounded (default 10 000, oldest-first
  eviction on overflow).
  """

  use ExUnit.Case, async: false

  alias Esr.Resource.DeadLetterQueue

  setup do
    pid = start_supervised!({DeadLetterQueue, name: :dl_test, max_entries: 3})
    %{dl: pid}
  end

  describe "enqueue/2 + list/1" do
    test "stores an entry and returns it from list" do
      :ok =
        DeadLetterQueue.enqueue(:dl_test, %{
          reason: :unknown_target,
          target: "thread:ghost",
          msg: "hi",
          source: "feishu-app:cli"
        })

      entries = DeadLetterQueue.list(:dl_test)
      assert length(entries) == 1
      [entry] = entries
      assert entry.reason == :unknown_target
      assert entry.target == "thread:ghost"
      assert is_binary(entry.id)
      assert is_integer(entry.ts_unix_ms)
    end

    test "list/1 returns empty when nothing enqueued" do
      assert DeadLetterQueue.list(:dl_test) == []
    end
  end

  describe "FIFO eviction when at capacity" do
    test "oldest entry dropped when max_entries exceeded" do
      for i <- 1..4 do
        :ok = DeadLetterQueue.enqueue(:dl_test, %{reason: :test, target: "t#{i}", msg: i})
      end

      entries = DeadLetterQueue.list(:dl_test)
      assert length(entries) == 3

      targets = Enum.map(entries, & &1.target) |> Enum.sort()
      # t1 is the oldest, should be evicted; t2/t3/t4 remain
      assert targets == ["t2", "t3", "t4"]
    end
  end

  describe "clear/1" do
    test "removes all entries" do
      :ok = DeadLetterQueue.enqueue(:dl_test, %{reason: :test, target: "x", msg: nil})
      assert length(DeadLetterQueue.list(:dl_test)) == 1

      :ok = DeadLetterQueue.clear(:dl_test)
      assert DeadLetterQueue.list(:dl_test) == []
    end
  end

  describe "telemetry" do
    test "enqueue fires [:esr, :deadletter, :event]" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:esr, :deadletter, :event]])

      :ok = DeadLetterQueue.enqueue(:dl_test, %{reason: :test, target: "y", msg: nil})

      assert_receive {[:esr, :deadletter, :event], ^ref, _measurements, metadata}
      assert metadata.reason == :test
      assert metadata.target == "y"
    end
  end
end

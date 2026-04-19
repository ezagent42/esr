defmodule Esr.Telemetry.BufferTest do
  @moduledoc """
  PRD 01 F15 — rolling ETS-backed telemetry buffer. Retention is
  configurable in minutes; default 15 per spec §3.6.
  """

  use ExUnit.Case, async: false

  alias Esr.Telemetry.Buffer

  setup do
    # Start the buffer fresh each test with a short retention window.
    pid = start_supervised!({Buffer, retention_minutes: 1, name: :buffer_test})
    %{buffer: pid}
  end

  describe "record/3" do
    test "stores an event retrievable via query/1", %{buffer: _pid} do
      :ok = Buffer.record(:buffer_test, [:esr, :actor, :spawned], %{count: 1}, %{actor_id: "x"})

      events = Buffer.query(:buffer_test, duration_seconds: 60)
      assert length(events) == 1

      [event] = events
      assert event.event == [:esr, :actor, :spawned]
      assert event.measurements == %{count: 1}
      assert event.metadata == %{actor_id: "x"}
      assert is_integer(event.ts_unix_ms)
    end
  end

  describe "query/1" do
    test "filters by duration_seconds" do
      :ok = Buffer.record(:buffer_test, [:esr, :x], %{}, %{})

      # Negative duration is strictly in the past, so nothing can match.
      events = Buffer.query(:buffer_test, duration_seconds: -1)
      assert events == []

      # Large duration sees the just-recorded event.
      events = Buffer.query(:buffer_test, duration_seconds: 60)
      assert length(events) == 1
    end

    test "returns [] when nothing recorded" do
      assert Buffer.query(:buffer_test, duration_seconds: 60) == []
    end
  end
end

defmodule Esr.Commands.TraceTest do
  @moduledoc """
  Unit coverage for `Esr.Commands.Trace` — dumps recent telemetry
  events from `Esr.Telemetry.Buffer` (named `:default` in production).

  The yaml `e2e-feishu-cc.yaml` Track-E previously exercised this via
  `esr trace --last 5m`. That scenario is deleted in this PR — these
  tests are the replacement coverage at the slash-command layer.
  """
  use ExUnit.Case, async: false

  alias Esr.Telemetry.Buffer
  alias Esr.Commands.Trace

  describe "Trace.execute/1" do
    test "returns serialised events from the default buffer" do
      Buffer.record(
        :default,
        [:esr, :handler, :called],
        %{duration_us: 42},
        %{actor_id: "thread:trace-test", session: "s1"}
      )

      assert {:ok, %{"text" => text}} = Trace.execute(%{})
      assert text =~ "events in last 900s"

      [_header | json_lines] = String.split(text, "\n", parts: 2)
      decoded = Jason.decode!(Enum.join(json_lines, "\n"))
      assert is_list(decoded)

      matching =
        Enum.find(decoded, fn entry ->
          entry["event"] == ["esr", "handler", "called"] and
            entry["metadata"]["actor_id"] == "thread:trace-test"
        end)

      assert matching != nil
      assert matching["measurements"]["duration_us"] == 42
    end

    test "respects duration_seconds=N (binary string from slash args)" do
      # Future-floor query — should match no events from the past.
      assert {:ok, %{"text" => text}} =
               Trace.execute(%{"args" => %{"duration_seconds" => "1"}})

      # 1-second window may or may not contain events depending on
      # other tests running concurrently. The shape assertion is
      # what matters: the duration is honoured and rendered.
      assert text =~ "in last 1s"
    end

    test "integer duration_seconds also accepted" do
      assert {:ok, %{"text" => text}} =
               Trace.execute(%{"args" => %{"duration_seconds" => 60}})

      assert text =~ "in last 60s"
    end

    test "invalid duration_seconds → falls back to default 900s" do
      assert {:ok, %{"text" => text}} =
               Trace.execute(%{"args" => %{"duration_seconds" => "not-a-number"}})

      assert text =~ "in last 900s"
    end
  end
end

defmodule Esr.Telemetry.AttachTest do
  @moduledoc """
  PRD 01 F16 — on application start the runtime attaches a handler
  that consumes every `[:esr, :*, :*]` telemetry event and writes it
  into `Esr.Telemetry.Buffer`. Verified by synthesising an event and
  querying the buffer.
  """

  use ExUnit.Case, async: false

  alias Esr.Telemetry.Buffer

  test "synthetic [:esr, :actor, :spawned] event is captured in the default buffer" do
    # Esr.Telemetry.Supervisor starts the default buffer + attaches the
    # [:esr, _, _] handler during application boot; we rely on that and
    # exercise the integration via the real event list.
    unique = "test-#{System.unique_integer([:positive])}"

    :telemetry.execute(
      [:esr, :actor, :spawned],
      %{count: 1},
      %{actor_id: unique}
    )

    # Handler runs synchronously, but ETS insert visibility across cores
    # warrants a tiny wait.
    :ok = Process.sleep(20)

    events =
      :default
      |> Buffer.query(duration_seconds: 60)
      |> Enum.filter(&(&1.metadata[:actor_id] == unique))

    assert length(events) == 1, "expected exactly one matching event; got #{length(events)}"
    [e] = events
    assert e.event == [:esr, :actor, :spawned]
    assert e.measurements == %{count: 1}
  end
end

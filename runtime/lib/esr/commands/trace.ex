defmodule Esr.Commands.Trace do
  @moduledoc """
  `trace` slash / admin-queue command — dump telemetry buffer events
  from the last `duration_seconds` window (default 900 = 15 min).

  Migrated from `EsrWeb.CliChannel.dispatch("cli:trace", ...)`.
  """

  @behaviour Esr.Role.Control

  alias Esr.Telemetry.Buffer
  alias Esr.Telemetry.Buffer.Event, as: TelemetryEvent

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(cmd) do
    args = Map.get(cmd, "args", %{})

    duration_s =
      case Map.get(args, "duration_seconds") do
        n when is_integer(n) and n > 0 ->
          n

        s when is_binary(s) ->
          case Integer.parse(s) do
            {n, ""} when n > 0 -> n
            _ -> 900
          end

        _ ->
          900
      end

    entries =
      :default
      |> Buffer.query(duration_seconds: duration_s)
      |> Enum.map(&serialise_event/1)

    body =
      case entries do
        [] -> "no telemetry events in last #{duration_s}s"
        _ -> "#{length(entries)} events in last #{duration_s}s\n" <> Jason.encode!(entries, pretty: true)
      end

    {:ok, %{"text" => body}}
  end

  defp serialise_event(%TelemetryEvent{} = event) do
    %{
      "ts_unix_ms" => event.ts_unix_ms,
      "event" => Enum.map(event.event, &to_string/1),
      "measurements" => event.measurements,
      "metadata" => event.metadata
    }
  end
end

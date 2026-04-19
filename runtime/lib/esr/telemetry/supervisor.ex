defmodule Esr.Telemetry.Supervisor do
  @moduledoc """
  Supervises telemetry subsystem: the default `Esr.Telemetry.Buffer`
  (spec §3.6) and the attached handler that feeds `[:esr, _, _]` events
  into it (PRD 01 F16).

  Children (in start order):
    1. Esr.Telemetry.Buffer — named :default, retention from app config
    2. Esr.Telemetry.AttachTask — one-shot Task that attaches the handler
       once the Buffer is up.
  """
  use Supervisor

  alias Esr.Telemetry.{Attach, Buffer}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    retention =
      Application.get_env(:esr, :telemetry_buffer_retention_minutes, 15)

    children = [
      {Buffer, name: :default, retention_minutes: retention},
      # Attach the handler once the Buffer is up. Task.start_link in a
      # supervised child: it runs, exits normally; :transient restart
      # strategy means we don't try again on clean exit.
      %{
        id: Esr.Telemetry.AttachTask,
        start: {Task, :start_link, [fn -> Attach.attach(:default) end]},
        restart: :transient,
        type: :worker
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Esr.Telemetry.Attach do
  @moduledoc """
  Bootstraps the `[:esr, _, _]` telemetry handler that feeds every ESR
  event into `Esr.Telemetry.Buffer` (PRD 01 F16).

  The handler is attached via `:telemetry.attach_many/4` at supervisor
  start time. Events are recorded into the buffer named `:default`.

  To enumerate the events we care about at boot, we attach to a bounded
  set of prefixes rather than a wildcard (:telemetry does not support
  wildcards). The list is derived from spec §3.6.
  """
  alias Esr.Telemetry.Buffer

  @events [
    [:esr, :actor, :spawned],
    [:esr, :actor, :stopped],
    [:esr, :actor, :paused],
    [:esr, :actor, :resumed],
    [:esr, :message, :received],
    [:esr, :message, :dispatched],
    [:esr, :directive, :issued],
    [:esr, :directive, :completed],
    [:esr, :directive, :timeout],
    [:esr, :handler, :called],
    [:esr, :handler, :violation],
    [:esr, :handler, :timeout],
    [:esr, :handler, :crashed],
    [:esr, :handler, :retry_exhausted],
    [:esr, :topology, :activated],
    [:esr, :topology, :deactivated],
    [:esr, :adapter, :crashed],
    [:esr, :deadletter, :event],
    [:esr, :state, :oversized_warning],
    [:esr, :ipc, :source_mismatch]
  ]

  @handler_id "esr-telemetry-buffer"

  @doc """
  Attach the buffer-feeding handler. Called by Esr.Telemetry.Supervisor
  after the default Buffer GenServer is running.

  Attaching twice with the same id is idempotent — :telemetry detaches
  the prior handler first.
  """
  @spec attach(atom()) :: :ok | {:error, :already_exists}
  def attach(buffer_name) do
    :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      @events,
      &__MODULE__.handle/4,
      %{buffer: buffer_name}
    )
  end

  @doc false
  @spec handle([atom()], map(), map(), map()) :: :ok
  def handle(event, measurements, metadata, %{buffer: buffer}) do
    Buffer.record(buffer, event, measurements, metadata)
  end

  @doc """
  Return the list of events this module attaches to. Handy for test
  synthesis (tests must emit events that match one of the attached
  prefixes).
  """
  @spec events() :: [[atom()]]
  def events, do: @events
end

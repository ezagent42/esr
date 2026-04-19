defmodule EsrWeb.CliChannel do
  @moduledoc """
  Phoenix.Channel for CLI control RPCs on ``cli:*`` topics (Phase 8c).

  The Python CLI opens a short-lived WS, joins a specific ``cli:<op>``
  topic, fires one ``cli_call`` event, and awaits the ``phx_reply``.
  Phase 8c base implementation echoes the payload so the full Python
  → Elixir → Python round-trip is verifiable without committing to
  specific control semantics; later iters replace the echo with the
  real dispatch table (cli:run → Topology.Registry.instantiate, etc.).
  """

  use Phoenix.Channel

  alias Esr.DeadLetter.Entry, as: DeadLetterEntry
  alias Esr.Telemetry.Buffer
  alias Esr.Telemetry.Buffer.Event, as: TelemetryEvent

  @impl Phoenix.Channel
  def join("cli:" <> _op = topic, _payload, socket) do
    {:ok, assign(socket, :topic, topic)}
  end

  def join(_topic, _payload, _socket) do
    {:error, %{reason: "invalid topic"}}
  end

  @impl Phoenix.Channel
  def handle_in("cli_call", payload, socket) do
    {:reply, {:ok, dispatch(socket.assigns.topic, payload)}, socket}
  end

  def handle_in(event, _payload, socket) do
    {:reply, {:error, %{reason: "unhandled event: #{event}"}}, socket}
  end

  @doc false
  @spec dispatch(String.t(), map()) :: map()
  def dispatch("cli:actors/list", _payload) do
    data =
      Esr.PeerRegistry.list_all()
      |> Enum.map(fn {actor_id, pid} ->
        %{"actor_id" => actor_id, "pid" => inspect(pid)}
      end)

    %{"data" => data}
  end

  def dispatch("cli:actors/inspect", %{"arg" => actor_id}) when is_binary(actor_id) do
    case Esr.PeerRegistry.lookup(actor_id) do
      {:ok, _pid} ->
        snap = Esr.PeerServer.describe(actor_id)

        data = %{
          "actor_id" => snap.actor_id,
          "actor_type" => snap.actor_type,
          "handler_module" => snap.handler_module,
          "paused" => snap.paused,
          "state" => stringify_keys(snap.state)
        }

        %{"data" => data}

      :error ->
        %{"data" => %{"error" => "actor not found", "actor_id" => actor_id}}
    end
  end

  def dispatch("cli:actors/inspect", _payload) do
    %{"data" => %{"error" => "missing 'arg' (actor_id)"}}
  end

  def dispatch("cli:drain", _payload) do
    handles = Esr.Topology.Registry.list_all()
    Enum.each(handles, &Esr.Topology.Registry.deactivate/1)

    %{
      "data" => %{
        "drained" => length(handles),
        "timeouts" => []
      }
    }
  end

  def dispatch("cli:debug/pause", %{"actor_id" => actor_id}) when is_binary(actor_id) do
    debug_toggle(actor_id, :pause)
  end

  def dispatch("cli:debug/resume", %{"actor_id" => actor_id}) when is_binary(actor_id) do
    debug_toggle(actor_id, :resume)
  end

  def dispatch("cli:debug/" <> _op, _payload) do
    %{"data" => %{"error" => "missing 'actor_id' in payload"}}
  end

  def dispatch("cli:deadletter/list", _payload) do
    data =
      Esr.DeadLetter
      |> Esr.DeadLetter.list()
      |> Enum.map(&serialise_dl_entry/1)

    %{"data" => data}
  end

  def dispatch("cli:deadletter/flush", _payload) do
    flushed = length(Esr.DeadLetter.list(Esr.DeadLetter))
    :ok = Esr.DeadLetter.clear(Esr.DeadLetter)
    %{"data" => %{"flushed" => flushed}}
  end

  def dispatch("cli:trace", payload) do
    duration_s =
      case Map.get(payload, "duration_seconds") do
        n when is_integer(n) -> n
        _ -> 900
      end

    entries =
      :default
      |> Buffer.query(duration_seconds: duration_s)
      |> Enum.map(&serialise_telemetry_event/1)

    %{"entries" => entries}
  end

  def dispatch(topic, payload) do
    # Phase 8c iterates: add a case clause per real cli:<op>. Until then,
    # echo so the Python CLI can observe that its call reached the runtime
    # and came back with a shaped response.
    %{"echoed" => payload, "topic" => topic}
  end

  @spec debug_toggle(String.t(), :pause | :resume) :: map()
  defp debug_toggle(actor_id, op) do
    case Esr.PeerRegistry.lookup(actor_id) do
      {:ok, _pid} ->
        :ok =
          case op do
            :pause -> Esr.PeerServer.pause(actor_id)
            :resume -> Esr.PeerServer.resume(actor_id)
          end

        snap = Esr.PeerServer.describe(actor_id)
        %{"data" => %{"actor_id" => actor_id, "paused" => snap.paused}}

      :error ->
        %{"data" => %{"error" => "actor not found", "actor_id" => actor_id}}
    end
  end

  @spec serialise_telemetry_event(TelemetryEvent.t()) :: map()
  defp serialise_telemetry_event(%TelemetryEvent{} = event) do
    %{
      "ts_unix_ms" => event.ts_unix_ms,
      "event" => Enum.map(event.event, &to_string/1),
      "measurements" => stringify_keys(event.measurements),
      "metadata" => stringify_keys(event.metadata)
    }
  end

  @spec stringify_keys(map()) :: map()
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {stringify_key(k), v} end)
  end

  @spec stringify_key(term()) :: String.t()
  defp stringify_key(k) when is_binary(k), do: k
  defp stringify_key(k), do: to_string(k)

  @spec serialise_dl_entry(DeadLetterEntry.t()) :: map()
  defp serialise_dl_entry(%DeadLetterEntry{} = entry) do
    %{
      "id" => entry.id,
      "ts_unix_ms" => entry.ts_unix_ms,
      "reason" => to_string(entry.reason),
      "target" => entry.target,
      "source" => entry.source,
      "msg" => inspect(entry.msg),
      "metadata" => entry.metadata
    }
  end
end

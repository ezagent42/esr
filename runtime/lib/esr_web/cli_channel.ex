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

  def dispatch(topic, payload) do
    # Phase 8c iterates: add a case clause per real cli:<op>. Until then,
    # echo so the Python CLI can observe that its call reached the runtime
    # and came back with a shaped response.
    %{"echoed" => payload, "topic" => topic}
  end

  @spec serialise_dl_entry(Esr.DeadLetter.Entry.t()) :: map()
  defp serialise_dl_entry(%Esr.DeadLetter.Entry{} = entry) do
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

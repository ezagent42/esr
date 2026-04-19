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
    response = %{"echoed" => payload, "topic" => socket.assigns.topic}
    {:reply, {:ok, response}, socket}
  end

  def handle_in(event, _payload, socket) do
    {:reply, {:error, %{reason: "unhandled event: #{event}"}}, socket}
  end
end

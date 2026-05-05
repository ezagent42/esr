defmodule EsrWeb.CliChannel do
  @moduledoc """
  Phoenix.Channel scaffolding for the legacy ``cli:*`` topic family.

  All former dispatch handlers have been migrated to slash commands —
  see `docs/notes/2026-05-05-cli-channel-migration.md`. This module
  remains as a thin protocol shell so the Python CLI's residual
  inbound joins return a structured `unknown_topic` error rather than
  a Phoenix-layer crash. The whole module + its socket route will be
  deleted alongside `py/src/esr/cli/` in step 12 of the migration.

  Live dispatch table: empty — every topic falls through to
  `unknown_topic`.
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
  def handle_in("cli_call", _payload, socket) do
    topic = socket.assigns.topic
    {:reply, {:ok, %{"data" => %{"error" => "unknown_topic: #{topic}"}}}, socket}
  end

  def handle_in(event, _payload, socket) do
    {:reply, {:error, %{reason: "unhandled event: #{event}"}}, socket}
  end
end

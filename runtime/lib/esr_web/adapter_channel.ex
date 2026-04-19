defmodule EsrWeb.AdapterChannel do
  @moduledoc """
  Phoenix.Channel handling one adapter topic — ``adapter:<name>/<instance_id>``.
  PRD 01 F09.

  Routing:
   - On join, the topic must already be bound to an actor_id via
     `Esr.AdapterHub.Registry`. Unbound topics are rejected so the
     adapter knows its instance wasn't registered correctly.
   - Inbound ``event`` messages: look up the owning PeerServer via
     AdapterHub.Registry → Esr.PeerRegistry and `send/2` the envelope
     as ``{:inbound_event, envelope}``.
   - Inbound ``directive_ack`` messages: route the same way, tagged
     ``{:directive_ack, envelope}``. Correlation-by-id happens inside
     the receiving PeerServer (F07).
  """

  use Phoenix.Channel

  alias Esr.AdapterHub.Registry, as: HubRegistry

  @impl Phoenix.Channel
  def join("adapter:" <> _rest = topic, _payload, socket) do
    case HubRegistry.lookup(topic) do
      {:ok, _actor_id} -> {:ok, assign(socket, :topic, topic)}
      :error -> {:error, %{reason: "no binding"}}
    end
  end

  @impl Phoenix.Channel
  def handle_in("event", envelope, socket) do
    forward(socket, {:inbound_event, envelope})
  end

  def handle_in("directive_ack", envelope, socket) do
    forward(socket, {:directive_ack, envelope})
  end

  def handle_in(event, _payload, socket) do
    {:reply, {:error, %{reason: "unhandled event: #{event}"}}, socket}
  end

  # Resolve topic → actor_id → pid → send the tagged message. Replies
  # :ok on success, :error with a reason when the binding or pid is
  # gone so the adapter can react (retry / drop / log).
  defp forward(socket, msg) do
    topic = socket.assigns.topic

    with {:ok, actor_id} <- HubRegistry.lookup(topic),
         [{pid, _}] <- Registry.lookup(Esr.PeerRegistry, actor_id) do
      send(pid, msg)
      {:reply, :ok, socket}
    else
      :error ->
        {:reply, {:error, %{reason: "no binding"}}, socket}

      [] ->
        {:reply, {:error, %{reason: "peer not alive"}}, socket}
    end
  end
end

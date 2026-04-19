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
    # Join succeeds regardless of whether a PeerServer is bound yet —
    # Python adapter workers are spawned *before* topology instantiation
    # so they can be on the topic when init_directive broadcasts. Routing
    # (forward/2) looks up the binding fresh at send time; an unbound
    # topic replies with an error but does not crash the channel.
    {:ok, assign(socket, :topic, topic)}
  end

  @impl Phoenix.Channel
  def handle_in("event", envelope, socket) do
    forward(socket, {:inbound_event, envelope})
  end

  # Envelope dispatch — the Python adapter_runner pushes everything as a
  # single "envelope" event with the kind inside the payload; dispatch to
  # the event-name-specific handlers so call sites stay unchanged.
  def handle_in("envelope", %{"kind" => "event"} = envelope, socket) do
    handle_in("event", envelope, socket)
  end

  def handle_in("envelope", %{"kind" => "directive_ack"} = envelope, socket) do
    handle_in("directive_ack", envelope, socket)
  end

  def handle_in("envelope", _envelope, socket) do
    {:reply, {:error, %{reason: "envelope missing/unknown kind"}}, socket}
  end

  def handle_in("directive_ack", %{"id" => id} = envelope, socket) do
    # Dual-publish: broadcast to directive_ack:<id> so the original
    # issuer (Instantiator for init_directive F13b, PeerServer for
    # regular Emits) can correlate; and deliver to the bound
    # PeerServer as a fallback tag so F09's routing stays intact.
    Phoenix.PubSub.broadcast(
      EsrWeb.PubSub,
      "directive_ack:" <> id,
      {:directive_ack, envelope}
    )

    forward(socket, {:directive_ack, envelope})
  end

  def handle_in("directive_ack", _envelope, socket) do
    {:reply, {:error, %{reason: "directive_ack missing id"}}, socket}
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

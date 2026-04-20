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

  # Boot handshake (capabilities spec §3.1, §4.1) — the Python adapter
  # process announces the union of permissions any handler modules it
  # happens to have loaded declared. Adapters typically load no handler
  # modules, so the list is usually empty — but when non-empty (tests,
  # future colocated workers) the names get registered in the same
  # Esr.Permissions.Registry the handler channel uses.
  def handle_in("envelope", %{"kind" => "handler_hello"} = envelope, socket) do
    perms =
      envelope
      |> Map.get("payload", %{})
      |> Map.get("permissions", [])

    register_permissions(perms, {:adapter, socket.assigns[:topic]})
    {:reply, :ok, socket}
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

  defp register_permissions(perms, declared_by) when is_list(perms) do
    for perm <- perms, is_binary(perm) do
      Esr.Permissions.Registry.register(perm, declared_by: declared_by)
    end

    :ok
  end

  defp register_permissions(_other, _declared_by), do: :ok

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

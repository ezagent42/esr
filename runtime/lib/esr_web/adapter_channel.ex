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

  @doc """
  Feature flag for the Peer/Session refactor (PR-2).

  Reads in this order:
    1. OS env var `ESR_USE_NEW_PEER_CHAIN` (`"1"`, `"true"`, `"TRUE"` → on;
       `"0"`, `"false"` → off; any other value → fall through)
    2. Application env `:esr, :use_new_peer_chain` (defaults `false`)

  When `true`, inbound Feishu frames are forwarded through
  `Esr.Peers.FeishuAppAdapter` (wired in P2-11). When `false`, the legacy
  `AdapterHub.Registry → PeerRegistry` path is used. Removed entirely in
  P2-17 once the new path is the sole path.
  """
  @spec new_peer_chain?() :: boolean()
  def new_peer_chain? do
    case System.get_env("ESR_USE_NEW_PEER_CHAIN") do
      v when v in ["1", "true", "TRUE"] -> true
      "0" -> false
      "false" -> false
      _ -> Application.get_env(:esr, :use_new_peer_chain, false)
    end
  end

  @impl Phoenix.Channel
  def join("adapter:" <> _rest = topic, _payload, socket) do
    # Join succeeds regardless of whether a PeerServer is bound yet —
    # Python adapter workers are spawned *before* topology instantiation
    # so they can be on the topic when init_directive broadcasts. Routing
    # (forward/2) looks up the binding fresh at send time; an unbound
    # topic replies with an error but does not crash the channel.
    {:ok, assign(socket, :topic, topic)}
  end

  # Capabilities spec §6.2/§6.3 — inbound event envelopes MUST carry
  # ``principal_id``. ``workspace_name`` may be nil (the "chat not
  # bound to any workspace" case; Lane A/B decide policy). A missing
  # ``principal_id`` means the adapter wasn't migrated to set it —
  # reject so the migration gap surfaces loudly instead of downstream
  # lanes silently denying every event.
  @impl Phoenix.Channel
  def handle_in("event", envelope, socket) when is_map(envelope) do
    case envelope["principal_id"] do
      pid when is_binary(pid) and pid != "" ->
        forward(socket, {:inbound_event, envelope})

      _ ->
        require Logger

        Logger.error(
          "adapter_channel: inbound event missing principal_id " <>
            "(topic=#{inspect(socket.assigns[:topic])} " <>
            "envelope_id=#{inspect(envelope["id"])}); rejecting"
        )

        {:reply,
         {:error,
          %{reason: "principal_id required on inbound event (capabilities §6.2)"}},
         socket}
    end
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
  #
  # When `new_peer_chain?/0` is on AND the topic is `adapter:feishu/<app_id>`,
  # inbound_event frames are rerouted through the new-chain peer
  # `Esr.Peers.FeishuAppAdapter` (registered under
  # `:feishu_app_adapter_<app_id>` in AdminSessionProcess — see P2-2/P2-11).
  # directive_ack and non-Feishu topics still flow through the legacy
  # AdapterHub.Registry → PeerRegistry path so the rest of the adapter
  # fleet (non-Feishu) is unaffected by the flag flip.
  defp forward(socket, {:inbound_event, envelope} = msg) do
    topic = socket.assigns.topic

    if new_peer_chain?() and String.starts_with?(topic, "adapter:feishu/") do
      case forward_to_new_chain(topic, envelope) do
        :ok -> {:reply, :ok, socket}
        :error -> {:reply, {:error, %{reason: "no feishu_app_adapter"}}, socket}
      end
    else
      forward_legacy(socket, msg)
    end
  end

  defp forward(socket, msg), do: forward_legacy(socket, msg)

  @doc """
  Forward an inbound Feishu envelope to the new-chain peer
  `Esr.Peers.FeishuAppAdapter` for `app_id` (parsed from `topic`).

  Returns `:ok` when the envelope was delivered (as `{:inbound_event, envelope}`
  to the adapter's mailbox), `:error` when no adapter is registered under
  `:feishu_app_adapter_<app_id>` in `Esr.AdminSessionProcess`.

  Exposed for direct unit testing of the routing path without spinning
  up a Phoenix.Channel socket.
  """
  @spec forward_to_new_chain(String.t(), map()) :: :ok | :error
  def forward_to_new_chain("adapter:feishu/" <> app_id, envelope) do
    sym = String.to_atom("feishu_app_adapter_#{app_id}")

    case Esr.AdminSessionProcess.admin_peer(sym) do
      {:ok, pid} ->
        send(pid, {:inbound_event, envelope})
        :ok

      :error ->
        require Logger
        Logger.warning("adapter_channel: no FeishuAppAdapter for app_id=#{app_id}")
        :error
    end
  end

  # Preserve the pre-P2-11 behaviour verbatim under a named helper so
  # the new branch can fall through to it without duplicating the
  # Registry-lookup logic.
  defp forward_legacy(socket, msg) do
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

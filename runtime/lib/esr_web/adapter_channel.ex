defmodule EsrWeb.AdapterChannel do
  @moduledoc """
  Phoenix.Channel handling one adapter topic — ``adapter:<name>/<instance_id>``.
  PRD 01 F09.

  Routing (post-P2-16):
   - On join, the topic is accepted regardless of binding state; Python
     adapter workers connect before the peer chain is up.
   - Inbound ``event`` messages on an ``adapter:feishu/<app_id>`` topic
     are forwarded into the new peer chain via
     `forward_to_new_chain/2` → `Esr.AdminSessionProcess.admin_peer/1`
     → `Esr.Peers.FeishuAppAdapter`. Non-Feishu topics and other event
     kinds fall into the legacy stub which logs + errors (P2-16 removed
     `Esr.AdapterHub.Registry`; the stub goes entirely in P2-17 when
     `USE_NEW_PEER_CHAIN` is retired).
  """

  use Phoenix.Channel

  @doc """
  Feature flag for the Peer/Session refactor (PR-2).

  Reads in this order:
    1. OS env var `ESR_USE_NEW_PEER_CHAIN` (`"1"`, `"true"`, `"TRUE"` → on;
       `"0"`, `"false"` → off; any other value → fall through)
    2. Application env `:esr, :use_new_peer_chain` (defaults `true` after
       P2-14)

  When `true`, inbound Feishu frames are forwarded through
  `Esr.Peers.FeishuAppAdapter` (wired in P2-11). When `false`, the legacy
  stub logs + errors — post-P2-16 the `AdapterHub.Registry → PeerRegistry`
  path is gone. The flag + stub are removed entirely in P2-17.
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

  # Resolve the inbound frame to the new peer chain. Post-P2-16 the
  # legacy `AdapterHub.Registry → PeerRegistry` lookup is gone — the
  # legacy stub now only logs + errors. When
  # `new_peer_chain?/0` is on AND the topic is `adapter:feishu/<app_id>`,
  # inbound_event frames are rerouted through the new-chain peer
  # `Esr.Peers.FeishuAppAdapter` (registered under
  # `:feishu_app_adapter_<app_id>` in AdminSessionProcess — see P2-2/P2-11).
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

  # Post-P2-16 stub: the legacy `AdapterHub.Registry → PeerRegistry`
  # lookup was deleted when the Registry itself was removed. Any call
  # that lands here means either (a) `ESR_USE_NEW_PEER_CHAIN=0` was set
  # explicitly or (b) a non-Feishu topic is still trying to use this
  # channel. Both are regressions post-P2-14 — log loudly and reply
  # with an actionable error. The stub is removed entirely in P2-17
  # together with the feature flag.
  defp forward_legacy(socket, _msg) do
    require Logger

    Logger.warning(
      "adapter_channel: legacy AdapterHub.Registry path invoked after P2-16 removal " <>
        "(topic=#{inspect(socket.assigns[:topic])}); set ESR_USE_NEW_PEER_CHAIN=1"
    )

    {:reply, {:error, %{reason: "legacy_path_removed"}}, socket}
  end
end

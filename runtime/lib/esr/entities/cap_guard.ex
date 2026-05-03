defmodule Esr.Entities.CapGuard do
  @moduledoc """
  Inbound gate (PR-21x) — Lane B capability enforcement for events
  arriving via `Esr.Entity.Server.handle_info({:inbound_event, _})`.

  Per capabilities spec §7.2 / §6.3 (CAP-4), every inbound envelope
  carrying a `principal_id` must satisfy
  `workspace:<ws>/<event_perm>` before the handler is invoked. On
  deny, this guard:

  1. Emits a `[:esr, :capabilities, :denied]` telemetry event so the
     deny is observable in operator dashboards.
  2. Rate-limits a Chinese deny DM per-principal (10-min window) and
     dispatches `{:outbound, %{"kind" => "reply", ...}}` to the
     originating Feishu app's FAA peer. The FAA's
     `handle_downstream/2` wraps the message into a directive on
     `adapter:feishu/<instance_id>`, the Python adapter renders it
     into a chat reply.

  ### Rationale (extracted from PR-21x)

  Before PR-21x, this logic was split across two modules:

  - The cap check + telemetry + `dispatch_deny_dm/1` lived in
    `Esr.Entity.Server` (private to that GenServer's hot path).
  - The rate-limit map (`deny_dm_last_emit`) and the
    `{:dispatch_deny_dm, _, _}` handle_info lived in
    `Esr.Entities.FeishuAppAdapter`.

  Two-step dispatch made the rate-limit per-(principal, FAA) instead
  of per-principal — a soft regression noted in the original
  drop-lane-a-auth spec §4 #2. Centralizing in CapGuard makes the
  rate-limit globally consistent across multi-FAA topologies.

  ### Public API

  - `check_inbound(envelope, required_perm, actor_id)` — returns
    `:granted` (caller proceeds with handler invocation) or
    `:denied` (caller drops the message). Side-effects on deny:
    telemetry + rate-limited DM dispatch.
  """

  @behaviour Esr.Role.Pipeline
  use GenServer
  require Logger

  @deny_dm_text "你无权使用此 bot，请联系管理员授权。"
  @default_interval_ms 10 * 60 * 1000
  @feishu_source_re ~r{^esr://[^/]+/adapters/feishu/([^/]+)$}

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec check_inbound(map(), String.t(), String.t() | atom()) ::
          :granted | :denied
  def check_inbound(envelope, required, actor_id) when is_binary(required) do
    principal_id = envelope["principal_id"]

    if granted?(principal_id, required) do
      :granted
    else
      :telemetry.execute(
        [:esr, :capabilities, :denied],
        %{count: 1},
        %{
          principal_id: principal_id,
          required_perm: required,
          lane: :B_inbound,
          actor_id: actor_id
        }
      )

      maybe_dispatch_deny_dm(envelope)
      :denied
    end
  end

  # ------------------------------------------------------------------
  # GenServer
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    {:ok, %{last_emit: %{}, interval_ms: interval_ms}}
  end

  @impl true
  def handle_call({:note_emit?, principal_id}, _from, state) do
    now = :erlang.monotonic_time(:millisecond)
    last = Map.get(state.last_emit, principal_id)

    if is_nil(last) or now - last >= state.interval_ms do
      {:reply, :emit, %{state | last_emit: Map.put(state.last_emit, principal_id, now)}}
    else
      {:reply, :rate_limited, state}
    end
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  # Esr.Capabilities.has?/2 guards on is_binary(principal_id). Tests
  # and internal routes can legitimately omit principal_id — treat
  # anything non-binary as "no grant" so the check always returns a
  # boolean and the deny path records the absent principal clearly.
  defp granted?(principal_id, required)
       when is_binary(principal_id) and is_binary(required) do
    Esr.Capabilities.has?(principal_id, required)
  end

  defp granted?(_, _), do: false

  defp maybe_dispatch_deny_dm(envelope) do
    with source when is_binary(source) <- envelope["source"],
         [_full, instance_id] <- Regex.run(@feishu_source_re, source),
         chat_id when is_binary(chat_id) and chat_id != "" <-
           get_in(envelope, ["payload", "args", "chat_id"]),
         principal_id when is_binary(principal_id) and principal_id != "" <-
           envelope["principal_id"] do
      case GenServer.call(__MODULE__, {:note_emit?, principal_id}) do
        :emit ->
          dispatch_dm_to_faa(instance_id, principal_id, chat_id)

        :rate_limited ->
          Logger.debug(
            "CapGuard Lane B deny-DM suppressed by rate-limit " <>
              "principal=#{inspect(principal_id)} chat_id=#{inspect(chat_id)} " <>
              "instance_id=#{inspect(instance_id)}"
          )
      end
    end

    :ok
  end

  defp dispatch_dm_to_faa(instance_id, principal_id, chat_id) do
    case Registry.lookup(Esr.Entity.Registry, "feishu_app_adapter_#{instance_id}") do
      [{faa_pid, _}] when is_pid(faa_pid) ->
        send(
          faa_pid,
          {:outbound,
           %{"kind" => "reply", "args" => %{"chat_id" => chat_id, "text" => @deny_dm_text}}}
        )

      _ ->
        Logger.warning(
          "CapGuard Lane B deny: no FAA registered for instance_id=#{inspect(instance_id)}; " <>
            "DM not sent (deny still effective; principal=#{inspect(principal_id)})"
        )
    end
  end
end

defmodule Esr.Scope.Process do
  @moduledoc """
  Per-Session GenServer holding core session state.

  PR-2 scope (minimal):
    - session_id (ULID string)
    - agent_name (e.g. "cc")
    - dir (workspace path)
    - chat_thread_key (%{chat_id:, app_id:}) — PR-21λ chat-current routing key
    - metadata (free-form map)

  PR-3 (P3-3a) adds the **session-scoped capability projection**
  (spec §3.3 / §3.5 + `docs/futures/peer-session-capability-projection.md`):
  at init, the Scope.Process pulls its principal's grants from the
  global `Esr.Resource.Capability.Grants` ETS table and caches them locally in
  `state.grants`. It subscribes to `grants_changed:<principal_id>` on
  `EsrWeb.PubSub` and re-projects on every broadcast. `has?/2` is served
  from the local map — **no global GenServer call per check** — so the
  data-plane read path doesn't contend with admin-plane writes.

  PR-6 (P6-A2) takes that one step further: the grants snapshot is
  mirrored into `:persistent_term` under `grants_pt_key(session_id)`
  so `has?/2` is a **zero-hop direct read** from any caller process —
  no Scope.Process GenServer round-trip per check. Writes (init,
  `:grants_changed`) still route through the Scope.Process owner and
  refresh the persistent term; `terminate/2` erases the key so sessions
  don't leak persistent-term entries. `:persistent_term.put/2` triggers
  a full global GC when the term changes, but grants changes are rare
  (per-session, at start + on explicit `:grants_changed` events) so the
  cost is amortised.

  Spec §3.5.
  """

  @behaviour Esr.Role.State
  use GenServer

  defstruct [:session_id, :agent_name, :dir, :chat_thread_key, :metadata, grants: []]

  # :persistent_term key for the per-session grants snapshot.
  # Reads on the hot path (`has?/2`) go directly through this key; the
  # owning Scope.Process is the only writer.
  defp grants_pt_key(session_id), do: {__MODULE__, :grants, session_id}

  def start_link(args) do
    sid = Map.fetch!(args, :session_id)
    GenServer.start_link(__MODULE__, args, name: via(sid))
  end

  def via(session_id),
    do: {:via, Registry, {Esr.Scope.Registry, {:session_process, session_id}}}

  def state(session_id), do: GenServer.call(via(session_id), :state)

  @doc """
  Session-scoped capability check (spec §3.3a).

  Reads from `:persistent_term` populated at init and refreshed via
  PubSub `:grants_changed` broadcasts — **zero-hop** (no global ETS
  lookup, no GenServer round-trip to either `Esr.Resource.Capability.Grants`
  _or_ the Scope.Process itself).

  Returns `false` when the session has no `principal_id` in its
  metadata (anonymous sessions can never hold capabilities) or when
  the session is unknown (defaults to an empty grants list).
  """
  def has?(session_id, permission) when is_binary(session_id) and is_binary(permission) do
    grants = :persistent_term.get(grants_pt_key(session_id), [])
    local_has?(grants, permission)
  end

  @impl true
  def init(args) do
    principal_id = extract_principal_id(Map.get(args, :metadata, %{}))
    session_id = Map.fetch!(args, :session_id)

    grants = fetch_grants(principal_id)
    # Publish to :persistent_term so has?/2 can be a zero-hop read
    # from any caller process. See module docstring (P6-A2).
    :persistent_term.put(grants_pt_key(session_id), grants)
    subscribe_to_grants_changes(principal_id)

    {:ok,
     %__MODULE__{
       session_id: session_id,
       agent_name: Map.fetch!(args, :agent_name),
       dir: Map.fetch!(args, :dir),
       chat_thread_key: Map.fetch!(args, :chat_thread_key),
       metadata: Map.get(args, :metadata, %{}),
       grants: grants
     }}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info(:grants_changed, state) do
    principal_id = extract_principal_id(state.metadata)
    new_grants = fetch_grants(principal_id)
    :persistent_term.put(grants_pt_key(state.session_id), new_grants)
    {:noreply, %{state | grants: new_grants}}
  end

  # Ignore unrelated info messages rather than crashing the Scope.Process.
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Clean up the persistent_term key on normal stop_session/shutdown
    # so we don't accumulate entries across session churn. Hard crashes
    # won't run terminate/2 — that's acceptable since the BEAM handles
    # resource reclaim on process death and grants are re-published on
    # next init/1 for the same session_id.
    _ = :persistent_term.erase(grants_pt_key(state.session_id))
    :ok
  end

  # --- internal ---

  defp extract_principal_id(metadata) when is_map(metadata) do
    Map.get(metadata, :principal_id) || Map.get(metadata, "principal_id")
  end

  defp extract_principal_id(_), do: nil

  # Pulls the principal's held-list directly from the Grants ETS table.
  # This is a one-time read at init (and on every grants_changed event)
  # — NOT a per-`has?` read. The table is `:named_table, :set,
  # read_concurrency: true` so concurrent reads here don't contend.
  defp fetch_grants(nil), do: []

  defp fetch_grants(principal_id) when is_binary(principal_id) do
    case :ets.lookup(:esr_capabilities_grants, principal_id) do
      [{^principal_id, held}] -> held
      _ -> []
    end
  rescue
    # The Grants table may not yet exist in pathological test setups
    # where a Scope.Process boots before Esr.Resource.Capability.Grants.
    ArgumentError -> []
  end

  defp subscribe_to_grants_changes(nil), do: :ok

  defp subscribe_to_grants_changes(principal_id) when is_binary(principal_id) do
    Phoenix.PubSub.subscribe(EsrWeb.PubSub, "grants_changed:#{principal_id}")
  end

  # Inline matcher mirroring `Esr.Resource.Capability.Grants.matches?/2`. Kept
  # local so `has?/2` never has to leave the Scope.Process — a pure
  # in-memory evaluation against the cached list.
  defp local_has?(grants, required) when is_list(grants) and is_binary(required) do
    Enum.any?(grants, &match_one?(&1, required))
  end

  defp local_has?(_, _), do: false

  defp match_one?("*", _), do: true

  defp match_one?(held, required) do
    with [h_scope, h_perm] <- String.split(held, "/", parts: 2),
         [h_prefix, h_name] <- String.split(h_scope, ":", parts: 2),
         [r_scope, r_perm] <- String.split(required, "/", parts: 2),
         [r_prefix, r_name] <- String.split(r_scope, ":", parts: 2),
         true <- h_prefix == r_prefix do
      seg_match?(h_name, r_name) and seg_match?(h_perm, r_perm)
    else
      _ -> false
    end
  end

  defp seg_match?("*", _), do: true
  defp seg_match?(a, a), do: true
  defp seg_match?(_, _), do: false
end

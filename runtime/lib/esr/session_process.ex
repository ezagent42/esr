defmodule Esr.SessionProcess do
  @moduledoc """
  Per-Session GenServer holding core session state.

  PR-2 scope (minimal):
    - session_id (ULID string)
    - agent_name (e.g. "cc")
    - dir (workspace path)
    - chat_thread_key (%{chat_id:, thread_id:})
    - metadata (free-form map)

  PR-3 (P3-3a) adds the **session-scoped capability projection**
  (spec §3.3 / §3.5 + `docs/futures/peer-session-capability-projection.md`):
  at init, the SessionProcess pulls its principal's grants from the
  global `Esr.Capabilities.Grants` ETS table and caches them locally in
  `state.grants`. It subscribes to `grants_changed:<principal_id>` on
  `EsrWeb.PubSub` and re-projects on every broadcast. `has?/2` is served
  from the local map — **no global GenServer call per check** — so the
  data-plane read path doesn't contend with admin-plane writes.

  Spec §3.5.
  """
  use GenServer

  defstruct [:session_id, :agent_name, :dir, :chat_thread_key, :metadata, grants: []]

  def start_link(args) do
    sid = Map.fetch!(args, :session_id)
    GenServer.start_link(__MODULE__, args, name: via(sid))
  end

  def via(session_id),
    do: {:via, Registry, {Esr.Session.Registry, {:session_process, session_id}}}

  def state(session_id), do: GenServer.call(via(session_id), :state)

  @doc """
  Session-scoped capability check (spec §3.3a).

  Reads from the local `state.grants` map populated at init and
  refreshed via PubSub `{:grants_changed, principal_id}` broadcasts —
  no global ETS lookup per call, no GenServer round-trip to
  `Esr.Capabilities.Grants`.

  Returns `false` when the session has no `principal_id` in its
  metadata (anonymous sessions can never hold capabilities).
  """
  def has?(session_id, permission) when is_binary(session_id) and is_binary(permission) do
    GenServer.call(via(session_id), {:has?, permission})
  end

  @impl true
  def init(args) do
    principal_id = extract_principal_id(Map.get(args, :metadata, %{}))

    grants = fetch_grants(principal_id)
    subscribe_to_grants_changes(principal_id)

    {:ok,
     %__MODULE__{
       session_id: Map.fetch!(args, :session_id),
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
  def handle_call({:has?, permission}, _from, state) do
    {:reply, local_has?(state.grants, permission), state}
  end

  @impl true
  def handle_info(:grants_changed, state) do
    principal_id = extract_principal_id(state.metadata)
    {:noreply, %{state | grants: fetch_grants(principal_id)}}
  end

  # Ignore unrelated info messages rather than crashing the SessionProcess.
  def handle_info(_msg, state), do: {:noreply, state}

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
    # where a SessionProcess boots before Esr.Capabilities.Grants.
    ArgumentError -> []
  end

  defp subscribe_to_grants_changes(nil), do: :ok

  defp subscribe_to_grants_changes(principal_id) when is_binary(principal_id) do
    Phoenix.PubSub.subscribe(EsrWeb.PubSub, "grants_changed:#{principal_id}")
  end

  # Inline matcher mirroring `Esr.Capabilities.Grants.matches?/2`. Kept
  # local so `has?/2` never has to leave the SessionProcess — a pure
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

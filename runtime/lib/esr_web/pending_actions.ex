defmodule EsrWeb.PendingActions do
  @moduledoc """
  TTL state machine for two-step destructive confirms (PR-21e, spec D12/D15).

  When an admin command emits a "confirm or cancel" prompt (currently
  only `/end-session`, but the mechanism is generic), the next inbound
  message from the same operator+chat is intercepted as the answer
  rather than routed to the active thread.

  Per D15, the interception point is in
  `Esr.Peers.FeishuAppAdapter.handle_upstream/2` (or equivalent
  inbound-entry hook) **before** slash-command parsing AND **before**
  the active-thread fallback. `intercept?/1` returns either:

  - `{:consume, :confirm | :cancel}` — caller invokes the registered
    callback and drops the message
  - `:passthrough` — caller routes the message as normal

  Pending entries auto-expire after `@ttl_ms` (default 60 s) so a
  forgotten prompt doesn't block the chat indefinitely.

  Storage: a single ETS table keyed by `{principal_id, chat_id}`.
  Cleanup: a `Process.send_after/3` `:expire` message per entry.
  """

  @behaviour Esr.Role.Pipeline
  use GenServer

  @table :esr_pending_actions
  @default_ttl_ms 60_000

  @type kind :: :end_session | atom()
  @type key :: {String.t(), String.t()}
  @type entry :: %{kind: kind(), payload: map(), reply_pid: pid() | nil}

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Register a pending action. The next message from
  `(principal_id, chat_id)` matching `confirm` / `cancel` (case-
  insensitive) consumes it. `payload` is opaque per-kind data the
  consumer hands back to the action's resolver. `reply_pid` (default
  `self()`) receives `{:pending_action, kind, :confirmed | :cancelled, payload}`
  on resolution.
  """
  @spec register(String.t(), String.t(), kind(), map(), keyword()) :: :ok
  def register(principal_id, chat_id, kind, payload, opts \\ [])
      when is_binary(principal_id) and is_binary(chat_id) and is_atom(kind) do
    reply_pid = Keyword.get(opts, :reply_pid, self())
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    GenServer.call(__MODULE__, {:register, {principal_id, chat_id}, kind, payload, reply_pid, ttl_ms})
  end

  @doc """
  Check whether an inbound message-text from `(principal_id, chat_id)`
  consumes a pending action. Caller is expected to hand `text` already
  trimmed; case-insensitive match on `confirm` / `cancel`.

  - `{:consume, :confirm}` — caller drops the message; consumer Pid is
    notified `{:pending_action, kind, :confirmed, payload}`
  - `{:consume, :cancel}` — same shape, `:cancelled`
  - `:passthrough` — no pending action, or the text doesn't match
  """
  @spec intercept?(String.t(), String.t(), String.t()) ::
          {:consume, :confirm | :cancel} | :passthrough
  def intercept?(principal_id, chat_id, text)
      when is_binary(principal_id) and is_binary(chat_id) and is_binary(text) do
    case classify(text) do
      :other ->
        :passthrough

      verdict ->
        GenServer.call(__MODULE__, {:intercept, {principal_id, chat_id}, verdict})
    end
  end

  @doc "Look up the current pending entry for a key (for tests / debug)."
  @spec lookup(String.t(), String.t()) :: {:ok, entry()} | :not_found
  def lookup(principal_id, chat_id) do
    case :ets.lookup(@table, {principal_id, chat_id}) do
      [{_, entry, _timer}] -> {:ok, entry}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc "Cancel a pending entry programmatically (e.g. on session shutdown)."
  @spec drop(String.t(), String.t()) :: :ok
  def drop(principal_id, chat_id) do
    GenServer.call(__MODULE__, {:drop, {principal_id, chat_id}})
  end

  # ------------------------------------------------------------------
  # GenServer
  # ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, key, kind, payload, reply_pid, ttl_ms}, _from, state) do
    cancel_existing(key)

    entry = %{kind: kind, payload: payload, reply_pid: reply_pid}
    timer = Process.send_after(self(), {:expire, key}, ttl_ms)
    :ets.insert(@table, {key, entry, timer})

    {:reply, :ok, state}
  end

  def handle_call({:intercept, key, verdict}, _from, state) do
    case :ets.lookup(@table, key) do
      [{_, %{kind: kind, payload: payload, reply_pid: pid} = _entry, timer}] ->
        cancel_timer(timer)
        :ets.delete(@table, key)

        if is_pid(pid) and Process.alive?(pid) do
          send(pid, {:pending_action, kind, verdict_atom(verdict), payload})
        end

        {:reply, {:consume, verdict}, state}

      [] ->
        {:reply, :passthrough, state}
    end
  end

  def handle_call({:drop, key}, _from, state) do
    cancel_existing(key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:expire, key}, state) do
    case :ets.lookup(@table, key) do
      [{_, %{kind: kind, payload: payload, reply_pid: pid}, _timer}] ->
        :ets.delete(@table, key)

        if is_pid(pid) and Process.alive?(pid) do
          send(pid, {:pending_action, kind, :expired, payload})
        end

      [] ->
        :ok
    end

    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp classify(text) do
    case text |> String.trim() |> String.downcase() do
      "confirm" -> :confirm
      "cancel" -> :cancel
      _ -> :other
    end
  end

  defp verdict_atom(:confirm), do: :confirmed
  defp verdict_atom(:cancel), do: :cancelled

  defp cancel_existing(key) do
    case :ets.lookup(@table, key) do
      [{_, _entry, timer}] ->
        cancel_timer(timer)
        :ets.delete(@table, key)

      [] ->
        :ok
    end
  end

  defp cancel_timer(timer) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel_timer(_), do: :ok
end

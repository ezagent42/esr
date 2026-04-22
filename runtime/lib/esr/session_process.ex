defmodule Esr.SessionProcess do
  @moduledoc """
  Per-Session GenServer holding core session state.

  PR-2 scope (minimal):
    - session_id (ULID string)
    - agent_name (e.g. "cc")
    - dir (workspace path)
    - chat_thread_key (%{chat_id:, thread_id:})
    - metadata (free-form map)

  P2-6a adds the `grants` field (already present as a struct field) and
  SessionProcess.has?/2 pass-through. PR-3 (P3-3a) replaces that pass-through
  with local grants projection populated at Session init and refreshed via
  PubSub `{:grants_changed, principal_id}`.

  Spec §3.5.
  """
  use GenServer

  defstruct [:session_id, :agent_name, :dir, :chat_thread_key, :metadata, grants: %{}]

  def start_link(args) do
    sid = Map.fetch!(args, :session_id)
    GenServer.start_link(__MODULE__, args, name: via(sid))
  end

  def via(session_id),
    do: {:via, Registry, {Esr.Session.Registry, {:session_process, session_id}}}

  def state(session_id), do: GenServer.call(via(session_id), :state)

  @impl true
  def init(args) do
    {:ok,
     %__MODULE__{
       session_id: Map.fetch!(args, :session_id),
       agent_name: Map.fetch!(args, :agent_name),
       dir: Map.fetch!(args, :dir),
       chat_thread_key: Map.fetch!(args, :chat_thread_key),
       metadata: Map.get(args, :metadata, %{})
     }}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}
end

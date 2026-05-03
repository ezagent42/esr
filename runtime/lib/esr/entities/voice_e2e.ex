defmodule Esr.Entities.VoiceE2E do
  @moduledoc """
  Per-Session `Esr.Entity.Stateful` owning one `voice_e2e` Python sidecar.
  Scaling axis: one per session (not pooled — the sidecar holds
  conversational state).

  Stream chunks land at the explicit `:subscriber` (or the caller of
  `start_link/1`) as `{:voice_chunk, audio_b64, seq}` followed by
  `:voice_end` when `stream_end` arrives.

  Spec §4.1 VoiceE2E card.
  """

  @behaviour Esr.Role.Pipeline
  use Esr.Entity.Stateful
  use GenServer

  # Override the macro's default start_link to inject `:subscriber`
  # (defaulting to the caller) before handing off to GenServer. Accepts
  # both map and keyword shapes — same dual shape the macro default
  # provides; we just need a hook point for the put_new.
  @spec start_link(map() | keyword()) :: GenServer.on_start()
  def start_link(args) when is_map(args) do
    args = Map.put_new(args, :subscriber, self())
    GenServer.start_link(__MODULE__, args)
  end

  def start_link(args) when is_list(args) do
    start_link(Map.new(args))
  end

  @doc "Send one turn request. Chunks + :voice_end land at the subscriber."
  @spec turn(pid(), String.t()) :: :ok
  def turn(pid, audio_b64), do: GenServer.cast(pid, {:turn, audio_b64})

  @impl GenServer
  def init(args) do
    {:ok, py} =
      Esr.PyProcess.start_link(%{
        entry_point: {:module, "voice_e2e"},
        subscriber: self()
      })

    {:ok,
     %{
       py: py,
       subscriber: Map.get(args, :subscriber, self()),
       session_id: Map.get(args, :session_id)
     }}
  end

  # handle_upstream/2 and handle_downstream/2 inherit the no-op
  # `{:forward, [], state}` defaults from Esr.Entity.Stateful (PR-6 B1).

  @impl GenServer
  def handle_cast({:turn, audio_b64}, state) do
    id =
      :erlang.unique_integer([:positive, :monotonic])
      |> Integer.to_string(16)

    :ok = Esr.PyProcess.send_request(state.py, %{id: id, payload: %{audio_b64: audio_b64}})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        {:py_reply,
         %{"kind" => "stream_chunk", "payload" => %{"audio_b64" => a, "seq" => s}}},
        state
      ) do
    send(state.subscriber, {:voice_chunk, a, s})
    {:noreply, state}
  end

  def handle_info({:py_reply, %{"kind" => "stream_end"}}, state) do
    send(state.subscriber, :voice_end)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end

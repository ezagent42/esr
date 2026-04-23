defmodule Esr.Peers.VoiceE2E do
  @moduledoc """
  Per-Session `Peer.Stateful` that owns one `voice_e2e` Python sidecar.

  Spec §4.1 VoiceE2E card + §8.1 streaming protocol. Holds
  conversational state on the Python side (one sidecar per session).
  Elixir side is a thin pipe: `turn/2` sends a request frame; stream
  chunks are forwarded to the session's neighbor (or the explicit
  `:subscriber`) as `{:voice_chunk, audio_b64, seq}` followed by
  `:voice_end` once `stream_end` arrives.

  Unlike VoiceASR/VoiceTTS, this peer is **not pooled** — each session
  has its own conversational thread. Start args:
    * `:session_id` (required) — session this peer belongs to
    * `:subscriber` (optional) — pid that receives stream tuples;
      defaults to the caller of `start_link/1`.

  Spec §4.1; expansion P4a-8.
  """
  use Esr.Peer.Stateful
  use GenServer

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

  @impl Esr.Peer.Stateful
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

  @impl Esr.Peer.Stateful
  def handle_upstream(_msg, state), do: {:forward, [], state}

  @impl Esr.Peer.Stateful
  def handle_downstream(_msg, state), do: {:forward, [], state}

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

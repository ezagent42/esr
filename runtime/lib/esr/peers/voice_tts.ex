defmodule Esr.Peers.VoiceTTS do
  @moduledoc """
  Pool-worker `Peer.Stateful` that owns one `voice_tts` Python sidecar.

  Spec §4.1 VoiceTTS card + §8.1 JSON-line IPC. Mirror of VoiceASR with
  data direction inverted: request is `{text: ...}`, reply is
  `{audio_b64: ...}`. Scaling axis: pool size (default 4, `pools.yaml`
  overridable) managed by `Esr.PeerPool` registered as `:voice_tts_pool`.

  Kept as a second module rather than parametrising VoiceASR because
  the pool-worker modules need distinct `worker:` atoms for
  `Esr.PeerPool.init/1`, and the request/reply shapes diverge when real
  engines land (PR-5).

  Spec §4.1; expansion P4a-5.
  """
  use Esr.Peer.Stateful
  use GenServer

  @default_timeout 5_000

  # --- public API ---------------------------------------------------------

  @spec start_link(map() | keyword()) :: GenServer.on_start()
  def start_link(args) when is_map(args), do: GenServer.start_link(__MODULE__, args)
  def start_link(args) when is_list(args), do: GenServer.start_link(__MODULE__, Map.new(args))

  @doc """
  Synthesize speech audio for `text`. Returns `{:ok, audio_b64}` or
  `{:error, reason}`.
  """
  @spec synthesize(pid(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def synthesize(pid, text, timeout \\ @default_timeout) do
    GenServer.call(pid, {:synthesize, text, timeout}, timeout + 500)
  end

  # --- Peer.Stateful callbacks --------------------------------------------

  @impl GenServer
  def init(_args) do
    {:ok, py} =
      Esr.PyProcess.start_link(%{
        entry_point: {:module, "voice_tts"},
        subscriber: self()
      })

    {:ok, %{py: py, pending: %{}}}
  end

  @impl Esr.Peer.Stateful
  def handle_upstream(_msg, state), do: {:forward, [], state}

  @impl Esr.Peer.Stateful
  def handle_downstream(_msg, state), do: {:forward, [], state}

  # --- GenServer callbacks ------------------------------------------------

  @impl GenServer
  def handle_call({:synthesize, text, _timeout}, from, state) do
    id = new_request_id()
    :ok = Esr.PyProcess.send_request(state.py, %{id: id, payload: %{text: text}})
    {:noreply, put_in(state.pending[id], from)}
  end

  @impl GenServer
  def handle_info({:py_reply, %{"id" => id, "kind" => "reply", "payload" => payload}}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {from, rest} ->
        reply =
          case payload do
            %{"audio_b64" => a} -> {:ok, a}
            _ -> {:error, {:unexpected_payload, payload}}
          end

        GenServer.reply(from, reply)
        {:noreply, %{state | pending: rest}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp new_request_id do
    :erlang.unique_integer([:positive, :monotonic])
    |> Integer.to_string(16)
  end
end

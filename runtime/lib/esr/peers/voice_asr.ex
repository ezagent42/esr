defmodule Esr.Peers.VoiceASR do
  @moduledoc """
  Pool-worker `Peer.Stateful` that owns one `voice_asr` Python sidecar.

  Spec §4.1 VoiceASR card + §8.1 JSON-line IPC. Scaling axis: pool size
  (default 4, honors `pools.yaml`) managed by
  `Esr.PeerPool` registered as `:voice_asr_pool`. Long-lived: the Python
  process stays alive between requests so the speech model remains
  loaded in real-engine mode (irrelevant for StubASR but the API shape
  is the same).

  ## Request-ID correlation

  The sidecar returns replies keyed by the request's `id`. VoiceASR
  holds a pending-map `%{id => GenServer.from()}`; each reply
  `{:py_reply, %{"id" => id, ...}}` resolves the matching waiter. This
  keeps concurrent calls against a pool worker safe (the pool is
  assumed to serialize but the worker's internal protocol still
  multiplexes for defense-in-depth).

  ## start_link arg shapes

  Accepts `map()` (unit tests pass `%{}`) or keyword-list / `[]` (as
  invoked by `Esr.PeerPool`'s `worker_mod.start_link([])`). Both
  normalise to `%{}` — init takes no args of its own; the sidecar is
  always `python -m voice_asr`.

  Spec §4.1; expansion P4a-5.
  """
  use Esr.Peer.Stateful
  use GenServer

  @default_timeout 5_000

  # --- public API ---------------------------------------------------------

  @doc """
  Start a VoiceASR worker. Accepts both the map shape used in unit tests
  (`%{}`) and the keyword-list shape passed by `Esr.PeerPool`.
  """
  @spec start_link(map() | keyword()) :: GenServer.on_start()
  def start_link(args) when is_map(args), do: GenServer.start_link(__MODULE__, args)
  def start_link(args) when is_list(args), do: GenServer.start_link(__MODULE__, Map.new(args))

  @doc """
  Transcribe a base64-encoded audio chunk.

  Blocking call; returns `{:ok, text}` or `{:error, reason}`. Uses the
  sidecar's pending-map with a request `id` so concurrent calls from the
  pool are disambiguated.
  """
  @spec transcribe(pid(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def transcribe(pid, audio_b64, timeout \\ @default_timeout) do
    GenServer.call(pid, {:transcribe, audio_b64, timeout}, timeout + 500)
  end

  # --- Peer.Stateful callbacks --------------------------------------------

  @impl GenServer
  def init(_args) do
    {:ok, py} =
      Esr.PyProcess.start_link(%{
        entry_point: {:module, "voice_asr"},
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
  def handle_call({:transcribe, audio_b64, _timeout}, from, state) do
    id = new_request_id()
    :ok = Esr.PyProcess.send_request(state.py, %{id: id, payload: %{audio_b64: audio_b64}})
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
            %{"text" => t} -> {:ok, t}
            _ -> {:error, {:unexpected_payload, payload}}
          end

        GenServer.reply(from, reply)
        {:noreply, %{state | pending: rest}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Short, ASCII, unique request id for the JSON line. `make_ref/0` is
  # unique per node; hashing keeps the wire payload compact.
  defp new_request_id do
    :erlang.unique_integer([:positive, :monotonic])
    |> Integer.to_string(16)
  end
end

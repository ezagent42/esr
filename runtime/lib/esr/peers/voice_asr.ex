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

  The sidecar returns replies keyed by the request's `id`. The shared
  `Esr.Peer.PyWorker` macro injects a pending-map `%{id =>
  GenServer.from()}`; each reply `{:py_reply, %{"id" => id, ...}}`
  resolves the matching waiter. This keeps concurrent calls against a
  pool worker safe (the pool is assumed to serialize but the worker's
  internal protocol still multiplexes for defense-in-depth).

  ## start_link arg shapes

  Inherits the dual-shape (`map() | keyword()`) `start_link/1` default
  from `Esr.Peer.Stateful` (PR-6 B1) — accepts the `%{}` shape used by
  unit tests and the keyword-list shape passed by `Esr.PeerPool`'s
  `worker_mod.start_link([])`.

  Spec §4.1; expansion P4a-5. PR-6 B2 absorbed the shared init/
  pending-map/handle_info boilerplate into `Esr.Peer.PyWorker`; only
  the public `transcribe/3` call and the reply-shape `extract_reply/1`
  live here now.
  """
  use Esr.Peer.PyWorker, module: "voice_asr"

  @default_timeout 5_000

  @doc """
  Transcribe a base64-encoded audio chunk.

  Blocking call; returns `{:ok, text}` or `{:error, reason}`. Uses the
  sidecar's pending-map with a request `id` so concurrent calls from the
  pool are disambiguated.
  """
  @spec transcribe(pid(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def transcribe(pid, audio_b64, timeout \\ @default_timeout) do
    GenServer.call(pid, {:rpc, %{audio_b64: audio_b64}, timeout}, timeout + 500)
  end

  @impl Esr.Peer.PyWorker
  def extract_reply(%{"text" => t}), do: {:ok, t}
  def extract_reply(other), do: {:error, {:unexpected_payload, other}}
end

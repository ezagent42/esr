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

  Spec §4.1; expansion P4a-5. PR-6 B2 absorbed the shared init/
  pending-map/handle_info boilerplate into `Esr.Peer.PyWorker`.
  """
  use Esr.Peer.PyWorker, module: "voice_tts"

  @default_timeout 5_000

  # start_link/1 inherits the dual-shape (map | keyword) default from
  # Esr.Peer.Stateful (PR-6 B1). Esr.PeerPool invokes it as
  # `worker_mod.start_link([])`; unit tests pass `%{}`.

  @doc """
  Synthesize speech audio for `text`. Returns `{:ok, audio_b64}` or
  `{:error, reason}`.
  """
  @spec synthesize(pid(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def synthesize(pid, text, timeout \\ @default_timeout) do
    GenServer.call(pid, {:rpc, %{text: text}, timeout}, timeout + 500)
  end

  @impl Esr.Peer.PyWorker
  def extract_reply(%{"audio_b64" => a}), do: {:ok, a}
  def extract_reply(other), do: {:error, {:unexpected_payload, other}}
end

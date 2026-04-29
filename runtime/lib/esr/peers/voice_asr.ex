defmodule Esr.Peers.VoiceASR do
  @moduledoc """
  Pool-worker `Esr.Peer.PyWorker` owning one `voice_asr` Python sidecar.
  Scaling axis: pool size (default 4, `pools.yaml` override) managed by
  `Esr.PeerPool` registered as `:voice_asr_pool`.

  Spec §4.1 VoiceASR card.
  """

  @behaviour Esr.Role.Pipeline
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

defmodule Esr.Entities.VoiceTTS do
  @moduledoc """
  Pool-worker `Esr.Entity.PyWorker` owning one `voice_tts` Python sidecar.
  Scaling axis: pool size (default 4, `pools.yaml` override) managed by
  `Esr.Entity.Pool` registered as `:voice_tts_pool`.

  Spec §4.1 VoiceTTS card.
  """

  @behaviour Esr.Role.Pipeline
  use Esr.Entity.PyWorker, module: "voice_tts"

  @default_timeout 5_000

  # start_link/1 inherits the dual-shape (map | keyword) default from
  # Esr.Entity.Stateful (PR-6 B1). Esr.Entity.Pool invokes it as
  # `worker_mod.start_link([])`; unit tests pass `%{}`.

  @doc """
  Synthesize speech audio for `text`. Returns `{:ok, audio_b64}` or
  `{:error, reason}`.
  """
  @spec synthesize(pid(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def synthesize(pid, text, timeout \\ @default_timeout) do
    GenServer.call(pid, {:rpc, %{text: text}, timeout}, timeout + 500)
  end

  @impl Esr.Entity.PyWorker
  def extract_reply(%{"audio_b64" => a}), do: {:ok, a}
  def extract_reply(other), do: {:error, {:unexpected_payload, other}}
end

defmodule Esr.Entity.VoiceTTSProxy do
  @moduledoc """
  Per-Session `Peer.Proxy` — session-local door to the VoiceTTS pool.

  Mirror of `Esr.Entity.VoiceASRProxy` in the outbound direction:
  `forward/2` acquires a TTS worker, calls
  `Esr.Entity.VoiceTTS.synthesize/2`, releases. Message tag `:voice_tts`,
  `@required_cap "peer_pool:voice_tts/acquire"`.

  ctx shape (computed at session-spawn time by Scope.Router):
    %{
      principal_id:    binary,
      pool_name:       atom,          # :voice_tts_pool in prod
      acquire_timeout: pos_integer    # ms; default 5_000
    }

  Spec §3.6, §4.1 VoiceTTSProxy card; expansion P4a-6.
  """

  @behaviour Esr.Role.Pipeline
  use Esr.Entity.Proxy
  @required_cap "peer_pool:voice_tts/acquire"

  @impl Esr.Entity.Proxy
  def forward({:voice_tts, text}, %{pool_name: pool_name} = ctx) when is_atom(pool_name) do
    timeout = Map.get(ctx, :acquire_timeout, 5_000)

    case Esr.Entity.Pool.acquire(pool_name, timeout: timeout) do
      {:ok, worker} ->
        try do
          case Esr.Entity.VoiceTTS.synthesize(worker, text, timeout) do
            {:ok, _} = ok -> ok
            {:error, reason} -> {:drop, {:py_error, reason}}
          end
        after
          Esr.Entity.Pool.release(pool_name, worker)
        end

      {:error, :pool_exhausted} ->
        {:drop, :pool_exhausted}
    end
  end

  def forward(_msg, _ctx), do: {:drop, :invalid_ctx}
end

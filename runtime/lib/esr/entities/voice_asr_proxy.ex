defmodule Esr.Entities.VoiceASRProxy do
  @moduledoc """
  Per-Session `Peer.Proxy` — session-local door to the VoiceASR pool.

  Spec §3.6 / §4.1: one of the two documented exceptions to the
  "static target" rule (VoiceTTSProxy is the other). `forward/2` does
  `Esr.Entity.Pool.acquire/2` against the pool named in ctx (in prod
  `:voice_asr_pool`, registered under Scope.Admin.Process), invokes
  `Esr.Entities.VoiceASR.transcribe/2`, then releases the worker back to
  the pool in an `after` clause.

  ctx shape (computed at session-spawn time by Scope.Router;
  P4a-9 spawn_args wiring):
    %{
      principal_id:    binary,        # who owns the session
      pool_name:       atom,          # :voice_asr_pool in prod
      acquire_timeout: pos_integer    # ms; default 5_000
    }

  `@required_cap "peer_pool:voice_asr/acquire"` triggers the PR-3
  `Esr.Entity.Proxy` macro's capability-check wrapper.

  Return shape:
    * `{:ok, text}`              — transcription succeeded
    * `{:drop, :cap_denied}`     — principal lacked permission
    * `{:drop, :pool_exhausted}` — pool had no slots
    * `{:drop, {:py_error, _}}`  — sidecar reported an error
    * `{:drop, :invalid_ctx}`    — malformed ctx map

  Spec §3.6, §4.1 VoiceASRProxy card; expansion P4a-6.
  """

  @behaviour Esr.Role.Pipeline
  use Esr.Entity.Proxy
  @required_cap "peer_pool:voice_asr/acquire"

  @impl Esr.Entity.Proxy
  def forward({:voice_asr, audio_b64}, %{pool_name: pool_name} = ctx) when is_atom(pool_name) do
    timeout = Map.get(ctx, :acquire_timeout, 5_000)

    case Esr.Entity.Pool.acquire(pool_name, timeout: timeout) do
      {:ok, worker} ->
        try do
          case Esr.Entities.VoiceASR.transcribe(worker, audio_b64, timeout) do
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

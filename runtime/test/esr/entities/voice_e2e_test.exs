defmodule Esr.Entities.VoiceE2ETest do
  @moduledoc """
  P4a-8 — per-session voice-to-voice peer with streaming output.

  Unlike VoiceASR/VoiceTTS, VoiceE2E is **not pooled**: each session
  owns one `voice_e2e` Python sidecar so conversational state is
  preserved across turns. The sidecar emits 3 `stream_chunk` frames
  followed by `stream_end` per request in stub mode; the Elixir peer
  surfaces these to the configured `:subscriber` as
  `{:voice_chunk, audio_b64, seq}` tuples plus a final `:voice_end`.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Esr.Entities.VoiceE2E

  test "turn/2 streams 3 chunks and a final :voice_end to the subscriber" do
    {:ok, pid} = VoiceE2E.start_link(%{session_id: "s-e2e-1", subscriber: self()})

    # Stub E2E engine emits 3 chunks for any input.
    :ok = VoiceE2E.turn(pid, "aGVsbG8=")

    for seq <- 0..2 do
      assert_receive {:voice_chunk, _audio, ^seq}, 3_000
    end

    assert_receive :voice_end, 3_000
    GenServer.stop(pid)
  end

  test "init accepts missing :subscriber by defaulting to the caller" do
    # When no explicit subscriber is given, the peer posts to the
    # start_link caller — matches the PyProcess convention.
    {:ok, pid} = VoiceE2E.start_link(%{session_id: "s-e2e-2"})
    :ok = VoiceE2E.turn(pid, "AAAA")

    assert_receive {:voice_chunk, _, 0}, 3_000
    assert_receive :voice_end, 3_000

    GenServer.stop(pid)
  end
end

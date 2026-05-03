defmodule Esr.Entities.VoiceTTSTest do
  @moduledoc """
  P4a-5 — `Esr.Entities.VoiceTTS` is a pool-worker `Peer.Stateful` that
  wraps one `voice_tts` Python sidecar.

  StubTTS echoes the input text as base64-encoded bytes. The round-trip
  shape (request `{text: ...}`, reply `{audio_b64: ...}`) mirrors
  VoiceASR but inverts the data direction.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Esr.Entities.VoiceTTS

  test "synthesize/2 returns {:ok, audio_b64} via stub TTS engine" do
    {:ok, pid} = VoiceTTS.start_link(%{})

    # StubTTS: "hi" → base64("hi") == "aGk="
    assert {:ok, "aGk="} = VoiceTTS.synthesize(pid, "hi", 3_000)

    GenServer.stop(pid)
  end

  test "concurrent synthesize calls resolve by request id" do
    {:ok, pid} = VoiceTTS.start_link(%{})

    inputs = ["a", "bb", "ccc", "dddd", "eeeee"]

    tasks =
      for t <- inputs do
        Task.async(fn -> VoiceTTS.synthesize(pid, t, 3_000) end)
      end

    results = Task.await_many(tasks, 5_000)
    assert Enum.all?(results, &match?({:ok, _}, &1))

    # base64 of each input
    expected =
      Enum.map(inputs, fn t -> Base.encode64(t) end)

    assert Enum.map(results, fn {:ok, a} -> a end) == expected

    GenServer.stop(pid)
  end
end

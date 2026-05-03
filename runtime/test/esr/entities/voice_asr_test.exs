defmodule Esr.Entities.VoiceASRTest do
  @moduledoc """
  P4a-5 — `Esr.Entities.VoiceASR` is a pool-worker `Peer.Stateful` that
  wraps one `voice_asr` Python sidecar (launched via PyProcess底座).

  Spec §4.1 VoiceASR card: receive audio bytes → return transcribed
  text. Invoked via `transcribe/2` by the per-session VoiceASRProxy.
  Tests the Elixir→Python→Elixir round-trip end-to-end using the real
  stub sidecar (no pure-Elixir mock — the IPC protocol is what we're
  covering).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Esr.Entities.VoiceASR

  test "transcribe/2 returns {:ok, text} via stub ASR engine" do
    {:ok, pid} = VoiceASR.start_link(%{})

    # StubASR returns "audio:<n>" where n = len(audio_b64)="AAAA" (4).
    assert {:ok, "audio:4"} = VoiceASR.transcribe(pid, "AAAA", 3_000)

    GenServer.stop(pid)
  end

  test "concurrent transcribe calls resolve by request id" do
    {:ok, pid} = VoiceASR.start_link(%{})

    tasks =
      for i <- 1..5 do
        Task.async(fn -> VoiceASR.transcribe(pid, String.duplicate("A", i), 3_000) end)
      end

    results = Task.await_many(tasks, 5_000)
    assert Enum.all?(results, &match?({:ok, _}, &1))
    # StubASR length matches: "audio:1", "audio:2", ..., "audio:5"
    assert Enum.map(results, fn {:ok, t} -> t end) ==
             Enum.map(1..5, &"audio:#{&1}")

    GenServer.stop(pid)
  end
end

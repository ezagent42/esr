"""voice_e2e sidecar — bidirectional voice-to-voice turn → streamed chunks.

Spec §8.1. Entry-point: `python -m voice_e2e` (wrapped by
`Esr.Peers.VoiceE2E` via `Esr.PyProcess` with
`entry_point: {:module, "voice_e2e"}`). Emits `stream_chunk` frames
terminated by a single `stream_end` per request, unlike ASR/TTS which
emit a single `reply`.
"""

"""voice_asr sidecar — receives audio bytes, returns transcribed text.

Spec §8.1. Entry-point: `python -m voice_asr` (wrapped by
`Esr.Peers.VoiceASR` via `Esr.PyProcess` with
`entry_point: {:module, "voice_asr"}`).
"""

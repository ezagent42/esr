"""voice_tts sidecar — receives text, returns synthesized audio_b64.

Spec §8.1. Entry-point: `python -m voice_tts` (wrapped by
`Esr.Peers.VoiceTTS` via `Esr.PyProcess` with
`entry_point: {:module, "voice_tts"}`).
"""

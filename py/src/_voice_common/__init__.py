"""Shared helpers for voice sidecars (voice_asr, voice_tts, voice_e2e).

Per-sidecar packages depend on this module for the JSON-line protocol
(`jsonline`) and engine selection (`engine`). This package is internal
to the voice split and not exposed via `esr.cli`.
"""

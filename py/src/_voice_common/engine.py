"""Voice-engine selection for sidecars.

Env var `VOICE_ENGINE=stub|volcengine` (or per-sidecar `VOICE_ASR_ENGINE`,
`VOICE_TTS_ENGINE`, `VOICE_E2E_ENGINE`) chooses a backend. Stub is the
default; CI runs entirely on stubs. PR-5 adds the real Volcengine
implementations behind the same interface.
"""
from __future__ import annotations

import os
from abc import ABC, abstractmethod


class VoiceASREngine(ABC):
    @abstractmethod
    def transcribe(self, audio_b64: str) -> str: ...


class VoiceTTSEngine(ABC):
    @abstractmethod
    def synthesize(self, text: str) -> str: ...  # returns audio_b64


class StubASR(VoiceASREngine):
    def transcribe(self, audio_b64: str) -> str:
        # Deterministic: "audio:<n_bytes>" so tests can assert without
        # needing a real speech model. Real engine lands in PR-5.
        return f"audio:{len(audio_b64)}"


class StubTTS(VoiceTTSEngine):
    def synthesize(self, text: str) -> str:
        # Echo the text as fake audio (b64-encoded bytes). Keeps the
        # round-trip shape honest without external API calls.
        import base64
        return base64.b64encode(text.encode("utf-8")).decode("ascii")


def select_asr() -> VoiceASREngine:
    which = os.environ.get("VOICE_ASR_ENGINE", os.environ.get("VOICE_ENGINE", "stub"))
    return {"stub": StubASR}[which]()


def select_tts() -> VoiceTTSEngine:
    which = os.environ.get("VOICE_TTS_ENGINE", os.environ.get("VOICE_ENGINE", "stub"))
    return {"stub": StubTTS}[which]()

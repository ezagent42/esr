"""Round-trip test for the voice_tts sidecar (text → audio_b64)."""
import base64
import json
import subprocess
import sys


def test_tts_sidecar_reply_shape() -> None:
    proc = subprocess.Popen(
        [sys.executable, "-m", "voice_tts"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={"VOICE_TTS_ENGINE": "stub", "PYTHONUNBUFFERED": "1"},
    )
    assert proc.stdin is not None and proc.stdout is not None

    req = {"id": "r1", "kind": "request", "payload": {"text": "hello"}}
    proc.stdin.write(json.dumps(req) + "\n")
    proc.stdin.flush()
    proc.stdin.close()

    reply = json.loads(proc.stdout.readline())
    assert reply["id"] == "r1"
    assert reply["kind"] == "reply"
    audio = reply["payload"]["audio_b64"]
    assert base64.b64decode(audio) == b"hello"

    assert proc.wait(timeout=5) == 0

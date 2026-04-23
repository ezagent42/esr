"""Round-trip test for the voice_asr sidecar.

Spawns `python -m voice_asr` as a subprocess, writes a request line to
its stdin, reads one reply line from its stdout. Exercises the same
contract Elixir-side `Esr.PyProcess` uses. Uses stub engine by default.
"""
import json
import subprocess
import sys


def test_asr_sidecar_reply_shape() -> None:
    proc = subprocess.Popen(
        [sys.executable, "-m", "voice_asr"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={"VOICE_ASR_ENGINE": "stub", "PYTHONUNBUFFERED": "1"},
    )
    assert proc.stdin is not None and proc.stdout is not None

    req = {"id": "r1", "kind": "request", "payload": {"audio_b64": "AAAA"}}
    proc.stdin.write(json.dumps(req) + "\n")
    proc.stdin.flush()
    proc.stdin.close()  # signal EOF → sidecar drains + exits

    line = proc.stdout.readline()
    reply = json.loads(line)
    assert reply["id"] == "r1"
    assert reply["kind"] == "reply"
    # StubASR returns "audio:<n>" where n = len(audio_b64).
    assert reply["payload"] == {"text": "audio:4"}

    assert proc.wait(timeout=5) == 0

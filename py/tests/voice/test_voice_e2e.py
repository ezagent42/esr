"""Streaming round-trip test for voice_e2e sidecar.

Sends one "turn" request; expects N stream_chunk frames followed by a
stream_end frame carrying the same id. The stub engine emits 3 chunks.
"""
import json
import subprocess
import sys


def test_e2e_sidecar_streams_chunks_then_end() -> None:
    proc = subprocess.Popen(
        [sys.executable, "-m", "voice_e2e"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={"VOICE_E2E_ENGINE": "stub", "PYTHONUNBUFFERED": "1"},
    )
    assert proc.stdin is not None and proc.stdout is not None

    req = {"id": "t1", "kind": "request", "payload": {"audio_b64": "aGVsbG8="}}
    proc.stdin.write(json.dumps(req) + "\n")
    proc.stdin.flush()
    proc.stdin.close()

    frames = []
    for line in proc.stdout:
        frames.append(json.loads(line))
        if frames[-1]["kind"] == "stream_end":
            break

    kinds = [f["kind"] for f in frames]
    assert kinds == ["stream_chunk", "stream_chunk", "stream_chunk", "stream_end"]
    assert all(f["id"] == "t1" for f in frames)
    assert proc.wait(timeout=5) == 0

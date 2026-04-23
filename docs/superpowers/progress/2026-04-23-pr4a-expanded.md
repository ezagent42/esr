# PR-4a Expanded: Voice-Gateway Split (voice-asr / voice-tts / voice-e2e sidecars + Elixir peers + cc-voice agent)

**Date**: 2026-04-23
**Branch**: `feature/peer-session-refactor` (worktree `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/`)
**Target duration**: 3-4 days.

**Prereq reading order** (load into working memory before starting any P4a-N task):

1. `docs/superpowers/progress/2026-04-23-pr3-snapshot.md` — PR-3 API shapes (erlexec底座, PyProcess, SessionRouter, AdminSession, PeerFactory, Peers.CC*, Peer.Proxy macro `@required_cap`, canonical capability names).
2. `.claude/skills/erlexec-elixir/SKILL.md` — voice sidecars all run on `Esr.PyProcess` which uses `:erlexec, wrapper: :plain` under the hood.
3. `docs/superpowers/plans/2026-04-22-peer-session-refactor-implementation.md` line 2274+ — PR-4a outline.
4. `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` §3.5 (cc-voice / voice-e2e agent defs), §4.1 (VoiceASR/TTS/E2E peer cards, VoiceASRProxy/TTSProxy pool-acquire exception), §8.1 (voice-gateway decomposition + JSON-line protocol), §8.4 (decommissioning strategy), §10.5 (PR-4a acceptance gates).
5. Existing code — `py/pyproject.toml` (dep layout, uv sources), `py/src/esr/` (no `voice_gateway/` exists today — this is greenfield), `runtime/lib/esr/py_process.ex` (entry-point contract, `{:py_reply, map}` subscriber pattern), `runtime/lib/esr/peer_pool.ex` (`acquire/release/{:error, :pool_exhausted}`), `runtime/lib/esr/peers/cc_{process,proxy}.ex` (reference pattern for Stateful+Proxy pair), `runtime/lib/esr/admin_session.ex` + `admin_session_process.ex` (register_admin_peer/2, :one_for_one children sup), `runtime/lib/esr/session_router.ex` (`@stateful_impls` set must grow; `build_ctx/2` dispatch for new proxies), `runtime/test/esr/fixtures/agents/simple.yaml` (agent-yaml fixture shape).
6. `runtime/test/esr/py_process_test.exs` + `runtime/test/fixtures/py/echo_sidecar.py` (template for the test pattern: script-mode sidecar, `assert_receive {:py_reply, _}`, `kill -0` cleanup loop).

---

## Scope / Non-scope

**In scope**:
- Three new Python packages `py/src/voice_asr/`, `py/src/voice_tts/`, `py/src/voice_e2e/` — each with `__main__.py`, JSON-line stdin loop, minimal deps, pytest round-trip test.
- Three Elixir peer worker modules `Esr.Peers.VoiceASR`, `Esr.Peers.VoiceTTS`, `Esr.Peers.VoiceE2E` that compose `Esr.Peer.Stateful` with `Esr.PyProcess` (sidecar-per-instance).
- Two Elixir proxy modules `Esr.Peers.VoiceASRProxy`, `Esr.Peers.VoiceTTSProxy` (`Peer.Proxy` with `@required_cap "peer_pool:voice_{asr,tts}/acquire"`; the one documented exception to the "static target" rule per spec §3.6 — `forward/2` does pool-acquire).
- Two pool supervisors `Esr.VoiceASRPoolSupervisor`, `Esr.VoiceTTSPoolSupervisor` as named `Esr.PeerPool` instances registered in `AdminSessionProcess` under `:voice_asr_pool` / `:voice_tts_pool`; bootstrapped under `AdminSession.ChildrenSupervisor` (size = 4 by default, honors optional `pools.yaml`).
- Two new entries in `agents.yaml` fixtures: `cc-voice` and `voice-e2e`.
- Integration tests for: sidecar round-trip, pool acquire/release/exhaustion, full `cc-voice` spawn (with stubbed voice sidecars so CI doesn't need Volcengine creds), full `voice-e2e` spawn.
- Registry growth: `SessionRouter.@stateful_impls` gains `Esr.Peers.VoiceASR`, `Esr.Peers.VoiceTTS`, `Esr.Peers.VoiceE2E`; `build_ctx/2` handles the two new proxy impls; `spawn_args/2` handles the three new stateful impls.
- Deletion tombstone (per spec §8.4): `py/voice_gateway/` never existed in this tree (verified), so the "delete the monolith" step is a **grep-assertion task**, not a file-removal task — see P4a-11 report section.

**Out of scope** (deferred to later PRs):
- Real Volcengine API calls. Each sidecar ships a **stub engine** behind a `VOICE_{ASR,TTS,E2E}_ENGINE=stub|volcengine` env var; `stub` is the default and echoes transcripts/audio deterministically so tests are hermetic.
- `pools.yaml` schema + hot-reload (spec §8.1 reserves this but only the override reader lands; the writer/CLI is PR-5).
- Multi-tenant conversational state eviction for `voice-e2e` (PR-5).
- Reverse-chain back-wiring for `cc-voice` outbound (the CC↔Tmux outbound leg is still tracked by the PR-3 tech-debt row "SessionRouter.build_neighbors/1 is forward-only"; this PR punches the outbound pipeline shape into yaml but the full reverse pass lands with the sibling fix).

---

## Task quick-reference table

| # | Task | File scope | Feishu-notify? | Depends on |
|---|---|---|---|---|
| P4a-0 | **Feishu PR-4a start notification** | — | ✅ start | — |
| P4a-1 | JSON-line protocol shared helpers + Python package skeleton | `py/src/_voice_common/{__init__.py,jsonline.py,engine.py}`, `py/pyproject.toml` (new workspace entry) | — | — |
| P4a-2 | `py/src/voice_asr/` sidecar + pytest | `py/src/voice_asr/{__init__.py,__main__.py}`, `py/tests/voice/test_voice_asr.py` | — | P4a-1 |
| P4a-3 | `py/src/voice_tts/` sidecar + pytest | `py/src/voice_tts/{__init__.py,__main__.py}`, `py/tests/voice/test_voice_tts.py` | — | P4a-1 |
| P4a-4 | `py/src/voice_e2e/` sidecar + pytest (streaming protocol) | `py/src/voice_e2e/{__init__.py,__main__.py}`, `py/tests/voice/test_voice_e2e.py` | ✅ after P4a-4 (milestone: three Python sidecars round-trip) | P4a-1 |
| P4a-5 | `Esr.Peers.VoiceASR` + `Esr.Peers.VoiceTTS` worker peers | `runtime/lib/esr/peers/voice_asr.ex`, `runtime/lib/esr/peers/voice_tts.ex`, tests | — | P4a-2, P4a-3 |
| P4a-6 | `Esr.Peers.VoiceASRProxy` + `Esr.Peers.VoiceTTSProxy` | `runtime/lib/esr/peers/voice_asr_proxy.ex`, `runtime/lib/esr/peers/voice_tts_proxy.ex`, tests | — | P4a-5 |
| P4a-7 | `Esr.VoiceASRPoolSupervisor` / `Esr.VoiceTTSPoolSupervisor` + AdminSession bootstrap + `pools.yaml` reader | `runtime/lib/esr/voice_pool_supervisor.ex` (thin wrapper around `Esr.PeerPool`), `admin_session.ex` updated children list, `runtime/lib/esr/pools.ex` (reader), test | ✅ after P4a-7 (milestone: pools + proxies live in AdminSession) | P4a-5, P4a-6 |
| P4a-8 | `Esr.Peers.VoiceE2E` (per-session, no pool) | `runtime/lib/esr/peers/voice_e2e.ex`, test | — | P4a-4 |
| P4a-9 | `agents.yaml` fixture: add `cc-voice` and `voice-e2e` + SessionRouter @stateful_impls / build_ctx / spawn_args updates | `runtime/test/esr/fixtures/agents/{voice.yaml,simple.yaml}`, `runtime/lib/esr/session_router.ex`, test | — | P4a-7, P4a-8 |
| P4a-10 | E2E integration: `/new-session --agent cc-voice` and `--agent voice-e2e` | `runtime/test/esr/integration/voice_e2e_test.exs`, `runtime/test/esr/integration/cc_voice_test.exs` | ✅ after P4a-10 (headline: voice sessions spawn + round-trip) | P4a-9 |
| P4a-11 | Delete `py/voice_gateway/` (NO-OP — doc commit + grep guard only) | commit message + `docs/notes/voice-gateway-never-materialized.md` | — | P4a-10 |
| P4a-12 | Open PR-4a draft + post link | `gh pr create` | ✅ PR opened | P4a-11 |
| P4a-13 | Wait for user review + merge | — | ✅ merged | P4a-12 |
| P4a-14 | Write `docs/superpowers/progress/<date>-pr4a-snapshot.md` + final notify | `docs/superpowers/progress/2026-04-23-pr4a-snapshot.md` (or the merge-day date) | ✅ final | P4a-13 |

**Feishu notification cadence**: PR-4a start (P4a-0) → milestone after P4a-4 (Python sidecars) → milestone after P4a-7 (Elixir pools + proxies in AdminSession) → milestone after P4a-10 (headline E2E green) → PR opened (P4a-12) → merged (P4a-13) → snapshot (P4a-14). **Six notifications across 3-4 days**; respects plan's "every 3-5 tasks" rule; P4a-14 rolls merge + snapshot into one notification if same day.

Use `mcp__openclaw-channel__reply` targeted at the author's configured chat (same chat as PR-2/PR-3 notifications).

---

## P4a-0 — Feishu PR-4a start notification

**Feishu-notify**: ✅ required (PR start).
**Files**: none.

### Step 1 — verify PR-3 is on `origin/main`

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor
git fetch origin
git log origin/main --oneline | grep -q "a416a25" && echo "PR-3 on main ✅"
```

Expected output: `PR-3 on main ✅`.

### Step 2 — confirm clean worktree on `feature/peer-session-refactor`

```bash
git status --short
git branch --show-current
```

Expected: empty `git status` output (or only PR-4a files), branch `feature/peer-session-refactor`.

### Step 3 — send Feishu notification

Body:

> PR-4a 启动 — voice-gateway split (三个 Python sidecar + Elixir peer 包装 + cc-voice / voice-e2e agents)。预计 3-4 天。里程碑：(1) 三个 Python sidecar JSON-line 协议打通 → (2) VoiceASR/TTS pool 进 AdminSession → (3) cc-voice + voice-e2e E2E 绿。计划：`docs/superpowers/progress/2026-04-23-pr4a-expanded.md`。

**Acceptance**: Feishu chat shows the message with a timestamp within the past minute.

---

## P4a-1 — JSON-line protocol shared helpers + Python package skeleton

**Feishu-notify**: no.
**Files**:
- Create `py/src/_voice_common/__init__.py`
- Create `py/src/_voice_common/jsonline.py` (read_request / write_reply / write_stream_chunk / write_stream_end)
- Create `py/src/_voice_common/engine.py` (abstract `VoiceEngine` + `StubEngine` selector)
- Modify `py/pyproject.toml` (add `voice_asr`, `voice_tts`, `voice_e2e`, `_voice_common` to packages.find; add pytest testpath `py/tests/voice`)

Rationale: three sidecars share 90% of the stdin-loop boilerplate. A tiny internal package `_voice_common` keeps them DRY without pulling a third-party framework.

### Step 1 — write the failing test

`py/tests/voice/test_jsonline.py`:

```python
"""Unit tests for _voice_common.jsonline — the stdin/stdout JSON-line
protocol helpers used by every voice sidecar.

Spec §8.1: requests `{"id": ..., "kind": "request", "payload": {...}}` in,
replies `{"id": ..., "kind": "reply", "payload": {...}}` out, streaming
flavour `{"id": ..., "kind": "stream_chunk", "payload": {...}}` +
`{"id": ..., "kind": "stream_end"}`.
"""
import io
import json
from _voice_common.jsonline import (
    read_requests,
    write_reply,
    write_stream_chunk,
    write_stream_end,
)


def test_read_requests_yields_parsed_objects() -> None:
    stdin = io.StringIO(
        '{"id":"r1","kind":"request","payload":{"text":"hi"}}\n'
        '{"id":"r2","kind":"request","payload":{}}\n'
    )
    out = list(read_requests(stdin))
    assert out == [
        {"id": "r1", "kind": "request", "payload": {"text": "hi"}},
        {"id": "r2", "kind": "request", "payload": {}},
    ]


def test_read_requests_skips_blank_and_bad_lines() -> None:
    stdin = io.StringIO(
        '\n'
        'not-json\n'
        '{"id":"r3","kind":"request","payload":{}}\n'
    )
    out = list(read_requests(stdin))
    assert out == [{"id": "r3", "kind": "request", "payload": {}}]


def test_write_reply_emits_single_json_line() -> None:
    buf = io.StringIO()
    write_reply(buf, "r1", {"text": "hello"})
    line = buf.getvalue()
    assert line.endswith("\n")
    parsed = json.loads(line)
    assert parsed == {"id": "r1", "kind": "reply", "payload": {"text": "hello"}}


def test_stream_chunk_and_end_are_distinct_kinds() -> None:
    buf = io.StringIO()
    write_stream_chunk(buf, "r1", {"bytes": "AAAA"})
    write_stream_end(buf, "r1")
    lines = [json.loads(l) for l in buf.getvalue().splitlines()]
    assert [l["kind"] for l in lines] == ["stream_chunk", "stream_end"]
    assert lines[0]["id"] == "r1" and lines[1]["id"] == "r1"
```

Run:

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/py
uv run pytest tests/voice/test_jsonline.py -v
```

Expected: `ModuleNotFoundError: No module named '_voice_common'`.

### Step 2 — create the helper module

`py/src/_voice_common/__init__.py`:

```python
"""Shared helpers for voice sidecars (voice_asr, voice_tts, voice_e2e).

Per-sidecar packages depend on this module for the JSON-line protocol
(`jsonline`) and engine selection (`engine`). This package is internal
to the voice split and not exposed via `esr.cli`.
"""
```

`py/src/_voice_common/jsonline.py`:

```python
"""JSON-line stdin/stdout protocol for voice sidecars (spec §8.1).

Each stdin line is a single JSON object with at minimum `id` and `kind`.
Replies and stream frames share the same shape so the Elixir side's
`Esr.PyProcess` can decode uniformly.
"""
from __future__ import annotations

import json
import sys
from typing import IO, Iterable


def read_requests(stream: IO[str] = sys.stdin) -> Iterable[dict]:
    """Yield parsed request objects from `stream` until EOF.

    Blank lines and lines that don't parse as JSON are skipped silently;
    operators can watch `logger.warning` in stderr for bad frames. The
    sidecar exits cleanly on EOF (stdin closed by Elixir owner).
    """
    for raw in stream:
        line = raw.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            # Spec §8.1: stderr reserved for logs; don't crash on bad
            # JSON — just drop the frame. The Elixir side will notice
            # any missing reply via its `id`-keyed pending-request map.
            sys.stderr.write(f"voice-sidecar: bad JSON line dropped: {line!r}\n")
            sys.stderr.flush()


def _write_frame(stream: IO[str], frame: dict) -> None:
    stream.write(json.dumps(frame) + "\n")
    stream.flush()


def write_reply(stream: IO[str], req_id: str, payload: dict) -> None:
    _write_frame(stream, {"id": req_id, "kind": "reply", "payload": payload})


def write_stream_chunk(stream: IO[str], req_id: str, payload: dict) -> None:
    _write_frame(stream, {"id": req_id, "kind": "stream_chunk", "payload": payload})


def write_stream_end(stream: IO[str], req_id: str) -> None:
    _write_frame(stream, {"id": req_id, "kind": "stream_end"})
```

`py/src/_voice_common/engine.py`:

```python
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
```

### Step 3 — update `py/pyproject.toml`

Add to `[tool.setuptools.packages.find]` (already scans `src/`, so new dirs are picked up automatically — verify with `uv pip install -e . && uv run python -c "import _voice_common"`). Add to `[tool.pytest.ini_options].testpaths`:

```toml
testpaths = [
    "tests",
    "tests/voice",
    "../adapters/feishu/tests",
    ...
]
```

### Step 4 — re-run

```bash
uv run pytest tests/voice/test_jsonline.py -v
```

Expected: 4 tests pass.

**Acceptance**:
- `uv run pytest tests/voice/test_jsonline.py` green (4 tests).
- `uv run python -c "from _voice_common import jsonline, engine"` exits 0.
- No changes to `runtime/` (Elixir-side untouched in this task).

---

## P4a-2 — `py/src/voice_asr/` sidecar + pytest

**Feishu-notify**: no.
**Files**:
- Create `py/src/voice_asr/__init__.py`
- Create `py/src/voice_asr/__main__.py`
- Create `py/tests/voice/test_voice_asr.py`

### Step 1 — failing test

`py/tests/voice/test_voice_asr.py`:

```python
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
```

Run:

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/py
uv run pytest tests/voice/test_voice_asr.py -v
```

Expected: fails with `No module named voice_asr`.

### Step 2 — implement the sidecar

`py/src/voice_asr/__init__.py`:

```python
"""voice_asr sidecar — receives audio bytes, returns transcribed text.

Spec §8.1. Entry-point: `python -m voice_asr` (wrapped by
`Esr.Peers.VoiceASR` via `Esr.PyProcess` with `entry_point: {:module, "voice_asr"}`).
"""
```

`py/src/voice_asr/__main__.py`:

```python
"""Entry-point for `python -m voice_asr`.

Reads JSON-line requests from stdin, transcribes via the selected
engine, writes JSON-line replies to stdout. Exits cleanly on stdin EOF.
"""
from __future__ import annotations

import sys

from _voice_common.engine import select_asr
from _voice_common.jsonline import read_requests, write_reply


def main() -> int:
    engine = select_asr()
    for req in read_requests(sys.stdin):
        if req.get("kind") != "request":
            continue
        req_id = req.get("id", "")
        payload = req.get("payload") or {}
        audio = payload.get("audio_b64", "")
        text = engine.transcribe(audio)
        write_reply(sys.stdout, req_id, {"text": text})
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

### Step 3 — re-run

```bash
uv run pytest tests/voice/test_voice_asr.py -v
```

Expected: 1 test passes.

**Acceptance**:
- `uv run python -m voice_asr < /dev/null` exits 0.
- `uv run pytest tests/voice/test_voice_asr.py` green.
- `ruff check py/src/voice_asr` clean.

---

## P4a-3 — `py/src/voice_tts/` sidecar + pytest

**Feishu-notify**: no.
**Files**:
- Create `py/src/voice_tts/__init__.py`
- Create `py/src/voice_tts/__main__.py`
- Create `py/tests/voice/test_voice_tts.py`

### Step 1 — failing test

`py/tests/voice/test_voice_tts.py`:

```python
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
```

### Step 2 — implement

`py/src/voice_tts/__main__.py`:

```python
"""Entry-point for `python -m voice_tts`."""
from __future__ import annotations

import sys

from _voice_common.engine import select_tts
from _voice_common.jsonline import read_requests, write_reply


def main() -> int:
    engine = select_tts()
    for req in read_requests(sys.stdin):
        if req.get("kind") != "request":
            continue
        req_id = req.get("id", "")
        text = (req.get("payload") or {}).get("text", "")
        audio_b64 = engine.synthesize(text)
        write_reply(sys.stdout, req_id, {"audio_b64": audio_b64})
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

`py/src/voice_tts/__init__.py` — one-line docstring mirroring voice_asr.

### Step 3 — re-run

```bash
uv run pytest tests/voice/test_voice_tts.py -v
```

Expected: 1 test passes.

**Acceptance**:
- `uv run python -m voice_tts < /dev/null` exits 0.
- `uv run pytest tests/voice/test_voice_tts.py` green.

---

## P4a-4 — `py/src/voice_e2e/` sidecar + pytest (streaming)

**Feishu-notify**: ✅ milestone — "Three Python voice sidecars (ASR/TTS/E2E) all passing JSON-line round-trip tests with stub engines. Next: Elixir peer wrappers."
**Files**:
- Create `py/src/voice_e2e/__init__.py`
- Create `py/src/voice_e2e/__main__.py`
- Create `py/tests/voice/test_voice_e2e.py`

This one differs from ASR/TTS: it emits `stream_chunk` frames for chunked audio output, terminated by a single `stream_end` frame. Elixir-side `VoiceE2E` peer accumulates chunks for its neighbor.

### Step 1 — failing test

`py/tests/voice/test_voice_e2e.py`:

```python
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
```

### Step 2 — implement

`py/src/voice_e2e/__main__.py`:

```python
"""Entry-point for `python -m voice_e2e`.

Bidirectional voice-to-voice: one request turn produces a stream of
stream_chunk frames followed by stream_end. Stub engine emits 3 fixed
chunks so tests are deterministic.
"""
from __future__ import annotations

import os
import sys

from _voice_common.jsonline import read_requests, write_stream_chunk, write_stream_end


def _stub_chunks(audio_b64: str) -> list[dict]:
    # Fixed 3-chunk reply for the stub engine; real engine streams from
    # a live TTS socket. Shape is stable so the Elixir peer's chunk
    # accumulator test can assert exact frames.
    return [
        {"audio_b64": audio_b64[:2], "seq": 0},
        {"audio_b64": audio_b64[2:4], "seq": 1},
        {"audio_b64": audio_b64[4:], "seq": 2},
    ]


def main() -> int:
    engine = os.environ.get("VOICE_E2E_ENGINE", os.environ.get("VOICE_ENGINE", "stub"))
    for req in read_requests(sys.stdin):
        if req.get("kind") != "request":
            continue
        req_id = req.get("id", "")
        audio = (req.get("payload") or {}).get("audio_b64", "")
        if engine == "stub":
            for chunk in _stub_chunks(audio):
                write_stream_chunk(sys.stdout, req_id, chunk)
            write_stream_end(sys.stdout, req_id)
        else:
            # Real engine lands in PR-5; keep the sidecar crashable so
            # ops knows env was misconfigured.
            sys.stderr.write(f"voice_e2e: unknown engine {engine!r}\n")
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

### Step 3 — re-run

```bash
uv run pytest tests/voice/ -v
```

Expected: all three sidecars green (ASR + TTS + E2E + jsonline = 7 tests total).

### Step 4 — Feishu notification

> PR-4a 进度：三个 Python sidecar (voice_asr / voice_tts / voice_e2e) JSON-line 协议全部打通。stub engine 下 pytest 全绿，共 7 个单测。下一步：Elixir side 的 peer wrapper (VoiceASR/TTS/E2E + Proxy + Pool)。

**Acceptance**:
- `cd py && uv run pytest tests/voice/ -v` green, 7 tests.
- `uv run python -m voice_e2e < /dev/null` exits 0 within 1s.

---

## P4a-5 — `Esr.Peers.VoiceASR` + `Esr.Peers.VoiceTTS` worker peers

**Feishu-notify**: no.
**Files**:
- Create `runtime/lib/esr/peers/voice_asr.ex`
- Create `runtime/lib/esr/peers/voice_tts.ex`
- Create `runtime/test/esr/peers/voice_asr_test.exs`
- Create `runtime/test/esr/peers/voice_tts_test.exs`

The pattern: `use Esr.Peer.Stateful`, delegate the sidecar lifecycle to a child `Esr.PyProcess`, keep a pending-request map keyed by request id so concurrent calls from the same pool worker resolve correctly.

### Step 1 — failing test (VoiceASR)

`runtime/test/esr/peers/voice_asr_test.exs`:

```elixir
defmodule Esr.Peers.VoiceASRTest do
  @moduledoc """
  P4a-5 — `Esr.Peers.VoiceASR` is a pool-worker `Peer.Stateful` that
  wraps one `voice_asr` Python sidecar (launched via PyProcess底座).

  Spec §4.1 VoiceASR card: receive audio bytes → return transcribed
  text. Invoked via `transcribe/2` by the per-session VoiceASRProxy.
  Tests the Elixir→Python→Elixir round-trip end-to-end using the real
  stub sidecar (no pure-Elixir mock — the IPC protocol is what we're
  covering).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Esr.Peers.VoiceASR

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
```

Run:

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime
mix test test/esr/peers/voice_asr_test.exs
```

Expected: `(UndefinedFunctionError) function Esr.Peers.VoiceASR.start_link/1 is undefined`.

### Step 2 — implement

`runtime/lib/esr/peers/voice_asr.ex`:

```elixir
defmodule Esr.Peers.VoiceASR do
  @moduledoc """
  Pool-worker `Peer.Stateful` that owns one `voice_asr` Python sidecar.

  Spec §4.1 VoiceASR card + §8.1 JSON-line IPC. Scaling axis: pool size
  (default 4, honors `pools.yaml`) managed by `Esr.VoiceASRPoolSupervisor`.
  Long-lived: the Python process stays alive between requests so the
  speech model remains loaded in real-engine mode (irrelevant for
  StubASR but the API shape is the same).

  ## Request-ID correlation

  The sidecar returns replies keyed by the request's `id`. VoiceASR
  holds a pending-map `%{id => GenServer.from()}`; each reply
  `{:py_reply, %{"id" => id, ...}}` resolves the matching waiter. This
  keeps concurrent calls against a pool worker safe (the pool is
  assumed to serialize but the worker's internal protocol still
  multiplexes for defense-in-depth).

  Spec §4.1; expansion P4a-5.
  """
  use Esr.Peer.Stateful
  use GenServer

  @default_timeout 5_000

  # --- public API ---------------------------------------------------------

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(args) when is_map(args), do: GenServer.start_link(__MODULE__, args)

  @doc """
  Transcribe a base64-encoded audio chunk.

  Blocking call; returns `{:ok, text}` or `{:error, reason}`. Uses the
  sidecar's pending-map with a request `id = make_ref()` so concurrent
  calls from the pool are disambiguated.
  """
  @spec transcribe(pid(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def transcribe(pid, audio_b64, timeout \\ @default_timeout) do
    GenServer.call(pid, {:transcribe, audio_b64, timeout}, timeout + 500)
  end

  # --- Peer.Stateful callbacks --------------------------------------------

  @impl Esr.Peer.Stateful
  def init(_args) do
    {:ok, py} =
      Esr.PyProcess.start_link(%{
        entry_point: {:module, "voice_asr"},
        subscriber: self()
      })

    {:ok, %{py: py, pending: %{}}}
  end

  @impl Esr.Peer.Stateful
  def handle_upstream(_msg, state), do: {:forward, [], state}

  @impl Esr.Peer.Stateful
  def handle_downstream(_msg, state), do: {:forward, [], state}

  # --- GenServer callbacks ------------------------------------------------

  @impl GenServer
  def handle_call({:transcribe, audio_b64, _timeout}, from, state) do
    id = encode_ref(make_ref())
    :ok = Esr.PyProcess.send_request(state.py, %{id: id, payload: %{audio_b64: audio_b64}})
    {:noreply, put_in(state.pending[id], from)}
  end

  @impl GenServer
  def handle_info({:py_reply, %{"id" => id, "kind" => "reply", "payload" => payload}}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} -> {:noreply, state}
      {from, rest} ->
        reply =
          case payload do
            %{"text" => t} -> {:ok, t}
            _ -> {:error, {:unexpected_payload, payload}}
          end

        GenServer.reply(from, reply)
        {:noreply, %{state | pending: rest}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Refs print as `#Reference<0.x.y.z>`; serialize to a short hex string
  # so the JSON line stays compact and ASCII.
  defp encode_ref(ref) do
    ref
    |> :erlang.ref_to_list()
    |> List.to_string()
    |> :erlang.phash2()
    |> Integer.to_string(16)
  end
end
```

`runtime/lib/esr/peers/voice_tts.ex` — near-identical, swap `voice_asr` → `voice_tts`, `transcribe/2` → `synthesize/2`, reply key `"text"` → `"audio_b64"`. (Kept as a second module rather than parametrizing because the pool-worker modules need distinct `worker:` atoms for `Esr.PeerPool.init/1` and the request/reply shapes diverge in PR-5 when real engines land.)

### Step 3 — mirror test for VoiceTTS

`runtime/test/esr/peers/voice_tts_test.exs` — identical shape, asserts StubTTS echoes text as base64: `VoiceTTS.synthesize(pid, "hi")` returns `{:ok, "aGk="}`.

### Step 4 — run tests

```bash
mix test test/esr/peers/voice_asr_test.exs test/esr/peers/voice_tts_test.exs --only integration
```

Expected: 4 tests pass.

**Acceptance**:
- Both peer modules compile clean (`mix compile --warnings-as-errors`).
- Integration tests green.
- Killing the VoiceASR pid causes the child Python `voice_asr` process to exit within 10s (inherited from `Esr.PyProcess` cleanup contract; can be asserted by extending `py_process_test.exs`'s `wait_for_exit` helper if desired — but not required for this task).

---

## P4a-6 — `Esr.Peers.VoiceASRProxy` + `Esr.Peers.VoiceTTSProxy`

**Feishu-notify**: no.
**Files**:
- Create `runtime/lib/esr/peers/voice_asr_proxy.ex`
- Create `runtime/lib/esr/peers/voice_tts_proxy.ex`
- Create `runtime/test/esr/peers/voice_asr_proxy_test.exs`
- Create `runtime/test/esr/peers/voice_tts_proxy_test.exs`

These are the "documented exception" proxies per spec §3.6 / §4.1 VoiceASRProxy card — their `forward/2` does a pool-acquire instead of forwarding to a static pid.

### Step 1 — failing test (VoiceASRProxy)

`runtime/test/esr/peers/voice_asr_proxy_test.exs`:

```elixir
defmodule Esr.Peers.VoiceASRProxyTest do
  @moduledoc """
  P4a-6 — `Esr.Peers.VoiceASRProxy` is the one documented exception to
  §3.6's "static target" rule (alongside VoiceTTSProxy and the
  slash-handler fallback): on forward, it acquires a VoiceASR worker
  from `Esr.VoiceASRPoolSupervisor` (held via `AdminSessionProcess`
  lookup `:voice_asr_pool`), invokes `transcribe/2`, then releases.

  `@required_cap "peer_pool:voice_asr/acquire"` enforces the capability
  check at proxy boundary (PR-3 macro extension). Tests stub the
  capability via `Process.put(:esr_cap_test_override, fn _, _ -> true end)`.
  """
  use ExUnit.Case, async: false

  alias Esr.Peers.VoiceASRProxy

  defmodule DummyPool do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])
    def init(opts), do: {:ok, opts}
    def handle_call({:acquire, _}, _from, s), do: {:reply, {:ok, s[:worker_pid]}, s}
    def handle_cast({:release, _}, s), do: {:noreply, s}
  end

  defmodule DummyWorker do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    def init(_), do: {:ok, nil}
    def handle_call({:transcribe, _, _}, _, s), do: {:reply, {:ok, "MOCK"}, s}
  end

  setup do
    Process.put(:esr_cap_test_override, fn _, _ -> true end)
    {:ok, w} = DummyWorker.start_link(nil)
    {:ok, p} = DummyPool.start_link(name: :vasr_test_pool, worker_pid: w)
    %{pool: p, worker: w}
  end

  test "forward/2 acquires, calls transcribe, releases", ctx do
    result =
      VoiceASRProxy.forward(
        {:voice_asr, "AAAA"},
        %{
          principal_id: "ou_test",
          pool_name: :vasr_test_pool,
          acquire_timeout: 200
        }
      )

    assert {:ok, "MOCK"} = result
  end

  test "capability denied short-circuits to {:drop, :cap_denied}" do
    Process.put(:esr_cap_test_override, fn _, _ -> false end)

    assert {:drop, :cap_denied} =
             VoiceASRProxy.forward({:voice_asr, "A"}, %{
               principal_id: "ou_test",
               pool_name: :vasr_test_pool
             })
  end

  test "pool exhaustion returns {:drop, :pool_exhausted}" do
    # Re-use the override but swap pool to one that always returns exhausted.
    defmodule ExhaustedPool do
      use GenServer
      def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)
      def init(_), do: {:ok, nil}
      def handle_call({:acquire, _}, _, s), do: {:reply, {:error, :pool_exhausted}, s}
    end

    {:ok, _} = ExhaustedPool.start_link(:vasr_exhausted)

    assert {:drop, :pool_exhausted} =
             VoiceASRProxy.forward({:voice_asr, "A"}, %{
               principal_id: "ou_test",
               pool_name: :vasr_exhausted
             })
  end
end
```

### Step 2 — implement

`runtime/lib/esr/peers/voice_asr_proxy.ex`:

```elixir
defmodule Esr.Peers.VoiceASRProxy do
  @moduledoc """
  Per-Session `Peer.Proxy` — session-local door to the VoiceASR pool.

  Spec §3.6 / §4.1: one of the two documented exceptions to the
  "static target" rule. `forward/2` does `Esr.PeerPool.acquire/2`
  against the pool named in ctx (`:voice_asr_pool` by convention),
  invokes `Esr.Peers.VoiceASR.transcribe/2`, then releases the worker.

  ctx shape (computed at session-spawn time by SessionRouter;
  §P4a-9 spawn_args wiring):
    %{
      principal_id:    binary,        # who owns the session
      pool_name:       atom,          # :voice_asr_pool in prod
      acquire_timeout: pos_integer    # ms; default 5_000
    }

  `@required_cap "peer_pool:voice_asr/acquire"` triggers the PR-3
  `Esr.Peer.Proxy` macro's capability-check wrapper.

  Return shape:
    * `{:ok, text}`           — transcription succeeded
    * `{:drop, :cap_denied}`  — principal lacked permission
    * `{:drop, :pool_exhausted}` — pool had no slots
    * `{:drop, {:py_error, _}}` — sidecar reported an error
  """
  use Esr.Peer.Proxy
  @required_cap "peer_pool:voice_asr/acquire"

  @impl Esr.Peer.Proxy
  def forward({:voice_asr, audio_b64}, %{pool_name: pool_name} = ctx) when is_atom(pool_name) do
    timeout = Map.get(ctx, :acquire_timeout, 5_000)

    case Esr.PeerPool.acquire(pool_name, timeout: timeout) do
      {:ok, worker} ->
        try do
          case Esr.Peers.VoiceASR.transcribe(worker, audio_b64, timeout) do
            {:ok, _} = ok -> ok
            {:error, reason} -> {:drop, {:py_error, reason}}
          end
        after
          Esr.PeerPool.release(pool_name, worker)
        end

      {:error, :pool_exhausted} ->
        {:drop, :pool_exhausted}
    end
  end

  def forward(_msg, _ctx), do: {:drop, :invalid_ctx}
end
```

`runtime/lib/esr/peers/voice_tts_proxy.ex` — identical shape; `@required_cap "peer_pool:voice_tts/acquire"`; calls `Esr.Peers.VoiceTTS.synthesize/2`; message tag `:voice_tts`.

### Step 3 — run tests

```bash
mix test test/esr/peers/voice_asr_proxy_test.exs test/esr/peers/voice_tts_proxy_test.exs
```

Expected: 6 tests green.

**Acceptance**:
- Both proxy modules compile (the `@required_cap` macro expansion already tested in PR-3).
- `@required_cap` test coverage for each (cap granted → success; denied → `{:drop, :cap_denied}`).
- Pool exhaustion path is covered (`{:drop, :pool_exhausted}`).
- Attempting to `def handle_call/3` inside a proxy module raises `CompileError` (inherited from `Esr.Peer.Proxy` macro; no extra test needed).

---

## P4a-7 — Pool supervisors + AdminSession bootstrap + `pools.yaml` reader

**Feishu-notify**: ✅ milestone — "VoiceASR/TTS pools live under AdminSession. pools.yaml override reader wired. Default size 4; max 128 inherited from `Esr.PeerPool`."
**Files**:
- Create `runtime/lib/esr/pools.ex` (`pools.yaml` reader; `pool_max(:voice_asr_pool) :: 4`)
- Create `runtime/test/esr/pools_test.exs`
- Modify `runtime/lib/esr/admin_session.ex` — add pool supervisors as children (see bootstrap note below)
- Modify `runtime/test/esr/admin_session_test.exs` — assert pool children show up in `Supervisor.which_children/1`
- Create `runtime/test/fixtures/pools/override.yaml`

### Bootstrap note

Pool supervisors are **named `Esr.PeerPool` instances**, not a new module. Register the pool pid in `AdminSessionProcess` under the symbolic name so `VoiceASRProxy` / `VoiceTTSProxy` can resolve via `Esr.AdminSessionProcess.admin_peer/1` → pid (but by PR-3 convention, the ctx carries the registered name atom directly, and the pool is started `name: :voice_asr_pool`).

### Step 1 — `pools.yaml` reader test

`runtime/test/esr/pools_test.exs`:

```elixir
defmodule Esr.PoolsTest do
  use ExUnit.Case, async: false

  @fixture Path.expand("../fixtures/pools/override.yaml", __DIR__)

  test "pool_max/1 returns default 4 when yaml absent" do
    assert Esr.Pools.pool_max(:voice_asr_pool, nil) == 4
    assert Esr.Pools.pool_max(:voice_tts_pool, nil) == 4
  end

  test "pool_max/1 reads override from pools.yaml" do
    assert Esr.Pools.pool_max(:voice_asr_pool, @fixture) == 8
    assert Esr.Pools.pool_max(:voice_tts_pool, @fixture) == 4  # not overridden
  end

  test "pool_max/1 caps at Esr.PeerPool.default_max_workers" do
    # An override higher than the global 128 cap is clamped.
    path = Path.join(System.tmp_dir!(), "pools_huge_#{System.unique_integer([:positive])}.yaml")
    File.write!(path, "pools:\n  voice_asr_pool: 9999\n")
    on_exit(fn -> File.rm_rf!(path) end)

    assert Esr.Pools.pool_max(:voice_asr_pool, path) == 128
  end
end
```

`runtime/test/fixtures/pools/override.yaml`:

```yaml
pools:
  voice_asr_pool: 8
```

### Step 2 — implement `Esr.Pools`

`runtime/lib/esr/pools.ex`:

```elixir
defmodule Esr.Pools do
  @moduledoc """
  Reader for optional `${ESRD_HOME}/<instance>/pools.yaml`. Returns
  per-pool max-worker overrides, clamped to `Esr.PeerPool.default_max_workers/0`
  (128).

  Voice pools default to 4. Spec §8.1 footnote (reserved for PR-5 to
  add a writer CLI / hot-reload).

  Unspecified pools fall back to the per-pool default map below; an
  absent or unreadable yaml is treated as "use defaults everywhere".
  """
  @voice_default 4
  @defaults %{
    voice_asr_pool: @voice_default,
    voice_tts_pool: @voice_default
  }

  @spec pool_max(atom(), Path.t() | nil) :: pos_integer()
  def pool_max(pool, path) do
    default = Map.get(@defaults, pool, Esr.PeerPool.default_max_workers())
    cap = Esr.PeerPool.default_max_workers()

    raw =
      case read_yaml(path) do
        {:ok, data} -> data[Atom.to_string(pool)] || default
        :error -> default
      end

    raw |> min(cap) |> max(1)
  end

  defp read_yaml(nil), do: :error
  defp read_yaml(path) do
    with true <- File.exists?(path),
         {:ok, parsed} <- YamlElixir.read_from_file(path),
         pools when is_map(pools) <- parsed["pools"] || %{} do
      {:ok, pools}
    else
      _ -> :error
    end
  end
end
```

### Step 3 — wire pools into AdminSession

Modify `runtime/lib/esr/admin_session.ex` `init/1` to add pool-supervisor children **via `DynamicSupervisor.start_child/2` in a post-init task** (not direct children), because the pool's `start_link` depends on `AdminSessionProcess` being up and we already use the children-sup + bootstrap pattern from P2:

Add to the existing `children_sup_name` DynamicSupervisor, via a new `Esr.AdminSession.bootstrap_voice_pools/1` helper called from `application.ex`:

`runtime/lib/esr/admin_session.ex` — add:

```elixir
  @doc """
  Start the VoiceASR/VoiceTTS pools under AdminSession's children
  supervisor. Called from `Esr.Application.start/2` after AdminSession
  is up (Risk F exception — bootstrap bypasses SessionRouter).

  Pool sizes come from `pools.yaml` via `Esr.Pools.pool_max/2`.
  Returns `:ok` on success; logs + returns `{:error, _}` if the pool
  registration fails (AdminSession stays up).
  """
  @spec bootstrap_voice_pools(Path.t() | nil) :: :ok | {:error, term()}
  def bootstrap_voice_pools(pools_yaml_path \\ nil) do
    sup = children_supervisor_name()

    with {:ok, asr_pid} <-
           DynamicSupervisor.start_child(sup, pool_spec(:voice_asr_pool,
             Esr.Peers.VoiceASR, pools_yaml_path)),
         :ok <- Esr.AdminSessionProcess.register_admin_peer(:voice_asr_pool, asr_pid),
         {:ok, tts_pid} <-
           DynamicSupervisor.start_child(sup, pool_spec(:voice_tts_pool,
             Esr.Peers.VoiceTTS, pools_yaml_path)),
         :ok <- Esr.AdminSessionProcess.register_admin_peer(:voice_tts_pool, tts_pid) do
      :ok
    end
  end

  defp pool_spec(name, worker_mod, pools_yaml) do
    max = Esr.Pools.pool_max(name, pools_yaml)
    %{
      id: name,
      start: {Esr.PeerPool, :start_link, [[name: name, worker: worker_mod, max: max]]},
      restart: :permanent,
      type: :worker
    }
  end
```

### Step 4 — `Esr.Application` invokes bootstrap

In `application.ex` `start/2` **after** `Supervisor.start_link(children, opts)` succeeds and before `restore_*` blocks run:

```elixir
_ = Esr.AdminSession.bootstrap_voice_pools(Esr.Paths.pools_yaml())
```

Add `pools_yaml/0` to `Esr.Paths`:

```elixir
def pools_yaml, do: Path.join(esrd_home(), "#{instance()}/pools.yaml")
```

### Step 5 — admin_session_test addition

Add a test:

```elixir
test "bootstrap_voice_pools/1 registers :voice_asr_pool and :voice_tts_pool admin peers" do
  start_supervised!({Esr.AdminSessionProcess, []})
  {:ok, _sup} = Esr.AdminSession.start_link(name: :vp_admin_sup,
                                            children_sup_name: :vp_children_sup)
  :ok = Esr.AdminSession.bootstrap_voice_pools(nil)

  assert {:ok, pid1} = Esr.AdminSessionProcess.admin_peer(:voice_asr_pool)
  assert is_pid(pid1)
  assert {:ok, pid2} = Esr.AdminSessionProcess.admin_peer(:voice_tts_pool)
  assert is_pid(pid2)

  # Pool can acquire/release a worker (real VoiceASR starts a Python sidecar —
  # gate behind :integration moduletag if needed).
end
```

### Step 6 — run

```bash
mix test test/esr/pools_test.exs test/esr/admin_session_test.exs
```

Expected: all new tests pass.

### Step 7 — Feishu notification

> PR-4a 里程碑：VoiceASR/VoiceTTS 池活跃在 AdminSession 下。默认池子大小 4（`pools.yaml` 可覆盖，上限 128）。Proxy 已可 acquire/release。下一步：VoiceE2E 每会话 peer + agents.yaml 接 `cc-voice` / `voice-e2e` + E2E 集成测试。

**Acceptance**:
- `Esr.AdminSessionProcess.admin_peer(:voice_asr_pool)` returns `{:ok, pid}` after `Esr.Application.start/2`.
- `pools.yaml` override raises the pool to 8 workers when set.
- `mix test` full suite remains green.

---

## P4a-8 — `Esr.Peers.VoiceE2E` (per-session, no pool)

**Feishu-notify**: no.
**Files**:
- Create `runtime/lib/esr/peers/voice_e2e.ex`
- Create `runtime/test/esr/peers/voice_e2e_test.exs`

`VoiceE2E` is per-session (holds conversational state in its Python sidecar). It mirrors `VoiceASR` in owning a `PyProcess` child but surfaces a streaming API: `VoiceE2E.turn/2` sends one request and the caller subscribes to a stream of `{:voice_chunk, audio_b64, seq}` messages terminated by `:voice_end`.

### Step 1 — failing test

`runtime/test/esr/peers/voice_e2e_test.exs`:

```elixir
defmodule Esr.Peers.VoiceE2ETest do
  @moduledoc "P4a-8 — per-session voice-to-voice peer w/ streaming."
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Esr.Peers.VoiceE2E

  test "turn/2 streams 3 chunks and a final :voice_end to the subscriber" do
    {:ok, pid} = VoiceE2E.start_link(%{session_id: "s-e2e-1", subscriber: self()})

    # Stub E2E engine emits 3 chunks for any input.
    :ok = VoiceE2E.turn(pid, "aGVsbG8=")

    for seq <- 0..2 do
      assert_receive {:voice_chunk, _audio, ^seq}, 3_000
    end

    assert_receive :voice_end, 3_000
    GenServer.stop(pid)
  end
end
```

### Step 2 — implement

`runtime/lib/esr/peers/voice_e2e.ex`:

```elixir
defmodule Esr.Peers.VoiceE2E do
  @moduledoc """
  Per-Session `Peer.Stateful` that owns one `voice_e2e` Python sidecar.

  Spec §4.1 VoiceE2E card + §8.1 streaming protocol. Holds
  conversational state on the Python side (one sidecar per session).
  Elixir side is a thin pipe: `turn/2` sends a request frame; stream
  chunks are forwarded to the session's neighbor (or the explicit
  `:subscriber`) as `{:voice_chunk, audio_b64, seq}` followed by
  `:voice_end` once `stream_end` arrives.

  Unlike VoiceASR/TTS, this peer is **not pooled** — each session has
  its own conversational thread.
  """
  use Esr.Peer.Stateful
  use GenServer

  def start_link(args) when is_map(args), do: GenServer.start_link(__MODULE__, args)

  @doc "Send one turn request; chunks + :voice_end land at the subscriber."
  def turn(pid, audio_b64), do: GenServer.cast(pid, {:turn, audio_b64})

  @impl Esr.Peer.Stateful
  def init(args) do
    {:ok, py} =
      Esr.PyProcess.start_link(%{
        entry_point: {:module, "voice_e2e"},
        subscriber: self()
      })

    {:ok,
     %{
       py: py,
       subscriber: Map.get(args, :subscriber, self()),
       session_id: Map.fetch!(args, :session_id)
     }}
  end

  @impl Esr.Peer.Stateful
  def handle_upstream(_msg, state), do: {:forward, [], state}

  @impl Esr.Peer.Stateful
  def handle_downstream(_msg, state), do: {:forward, [], state}

  @impl GenServer
  def handle_cast({:turn, audio_b64}, state) do
    id = System.unique_integer([:positive]) |> Integer.to_string(16)
    :ok = Esr.PyProcess.send_request(state.py, %{id: id, payload: %{audio_b64: audio_b64}})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:py_reply, %{"kind" => "stream_chunk", "payload" => %{"audio_b64" => a, "seq" => s}}}, state) do
    send(state.subscriber, {:voice_chunk, a, s})
    {:noreply, state}
  end

  def handle_info({:py_reply, %{"kind" => "stream_end"}}, state) do
    send(state.subscriber, :voice_end)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
```

### Step 3 — run

```bash
mix test test/esr/peers/voice_e2e_test.exs --only integration
```

Expected: 1 test green.

**Acceptance**:
- Round-trip streams 3 chunks + `:voice_end` within 3s.
- `mix compile --warnings-as-errors` clean.
- On `GenServer.stop(pid)`, the child `voice_e2e` Python process exits within 10s (inherited from PyProcess; can be asserted optionally).

---

## P4a-9 — `agents.yaml` fixture: `cc-voice` / `voice-e2e` + SessionRouter updates

**Feishu-notify**: no.
**Files**:
- Create `runtime/test/esr/fixtures/agents/voice.yaml`
- Modify `runtime/lib/esr/session_router.ex` (`@stateful_impls` + `build_ctx/2` + `spawn_args/2`)
- Modify `runtime/test/esr/session_router_test.exs` (add cc-voice and voice-e2e cases)

### Step 1 — yaml fixture

`runtime/test/esr/fixtures/agents/voice.yaml`:

```yaml
agents:
  cc-voice:
    description: "CC + voice I/O (voice in → ASR → CC → TTS → voice out)"
    capabilities_required:
      - session:default/create
      - tmux:default/spawn
      - handler:cc_adapter_runner/invoke
      - peer_pool:voice_asr/acquire
      - peer_pool:voice_tts/acquire
    pipeline:
      inbound:
        - { name: feishu_chat_proxy, impl: Esr.Peers.FeishuChatProxy }
        - { name: voice_asr,         impl: Esr.Peers.VoiceASRProxy }
        - { name: cc_proxy,          impl: Esr.Peers.CCProxy }
        - { name: cc_process,        impl: Esr.Peers.CCProcess }
        - { name: tmux_process,      impl: Esr.Peers.TmuxProcess }
      outbound:
        - tmux_process
        - cc_process
        - cc_proxy
        - voice_tts
        - feishu_chat_proxy
    proxies:
      - { name: feishu_app_proxy, impl: Esr.Peers.FeishuAppProxy, target: "admin::feishu_app_adapter_${app_id}" }
      - { name: voice_asr,        impl: Esr.Peers.VoiceASRProxy,  target: "admin::voice_asr_pool" }
      - { name: voice_tts,        impl: Esr.Peers.VoiceTTSProxy,  target: "admin::voice_tts_pool" }
    params:
      - { name: dir,    required: true,  type: path }
      - { name: app_id, required: false, default: "default", type: string }

  voice-e2e:
    description: "End-to-end voice LLM; agent as side-input, no CC"
    capabilities_required:
      - session:default/create
      - handler:voice_e2e/invoke
    pipeline:
      inbound:
        - { name: feishu_chat_proxy, impl: Esr.Peers.FeishuChatProxy }
        - { name: voice_e2e,         impl: Esr.Peers.VoiceE2E }
      outbound:
        - voice_e2e
        - feishu_chat_proxy
    proxies:
      - { name: feishu_app_proxy, impl: Esr.Peers.FeishuAppProxy, target: "admin::feishu_app_adapter_${app_id}" }
    params: []
```

Note on pipeline placement of proxies in `cc-voice`: the yaml above lists `voice_asr` twice — once in `inbound` (where `SessionRouter.spawn_pipeline/3` sees the *proxy* impl and records it symbolically but spawns nothing — proxies aren't Stateful) and once in `proxies` (where the target pool name is attached). This duplicate is intentional: it tells the router "the position of the voice_asr proxy in the chain is between `feishu_chat_proxy` and `cc_proxy`", which matters for `build_neighbors/1` wiring. The dedup already happens via `@stateful_impls` membership check in `spawn_one/5`.

### Step 2 — SessionRouter additions

`runtime/lib/esr/session_router.ex`:

1. Grow `@stateful_impls`:

```elixir
@stateful_impls MapSet.new([
                  "Esr.Peers.FeishuChatProxy",
                  "Esr.Peers.CCProcess",
                  "Esr.Peers.TmuxProcess",
                  "Esr.Peers.FeishuAppAdapter",
                  # P4a-9 additions
                  "Esr.Peers.VoiceE2E"
                ])
```

(VoiceASR / VoiceTTS are pooled in AdminSession and **not** spawned per-session; the `cc-voice` pipeline references them only via the proxies.)

2. Add `build_ctx/2` clauses:

```elixir
defp build_ctx(%{"impl" => "Esr.Peers.VoiceASRProxy"}, params) do
  %{
    principal_id: get_param(params, :principal_id),
    pool_name: :voice_asr_pool,
    acquire_timeout: 5_000
  }
end

defp build_ctx(%{"impl" => "Esr.Peers.VoiceTTSProxy"}, params) do
  %{
    principal_id: get_param(params, :principal_id),
    pool_name: :voice_tts_pool,
    acquire_timeout: 5_000
  }
end
```

3. Add `spawn_args/2` for `VoiceE2E`:

```elixir
defp spawn_args(%{"impl" => "Esr.Peers.VoiceE2E"}, params) do
  %{
    session_id: get_param(params, :session_id),
    subscriber: nil   # SessionRouter fills this post-spawn; see drift note
  }
end
```

**Drift note** (add to router moduledoc): `VoiceE2E.start_link` expects a `:session_id` key, but `Esr.PeerFactory.spawn_peer/5` already merges `%{session_id: session_id}` into init_args — so the `spawn_args/2` clause above is a no-op placeholder and can be omitted. Listed for explicitness only.

### Step 3 — session_router_test additions

Add to `runtime/test/esr/session_router_test.exs`:

```elixir
test "create_session/1 with agent=cc-voice spawns FCP + CCProcess + TmuxProcess + VoiceE2E-less chain" do
  # Load fixture + stub AdminSessionProcess + assert VoiceASRProxy is
  # recorded as {:proxy_module, Esr.Peers.VoiceASRProxy} (not spawned).
  ...
end

test "create_session/1 with agent=voice-e2e spawns FCP + VoiceE2E" do
  ...
end
```

### Step 4 — run

```bash
mix test test/esr/session_router_test.exs test/esr/session_registry_test.exs
```

Expected: previous tests + new cases all green.

**Acceptance**:
- `SessionRegistry.agent_def("cc-voice")` / `agent_def("voice-e2e")` return compiled defs.
- Spawning a `cc-voice` session produces: 3 Stateful peers (FCP, CCProcess, TmuxProcess) + 3 proxy markers (feishu_app_proxy, voice_asr, voice_tts) in the refs map.
- VoiceASR/VoiceTTS are **not** spawned per-session (they live in the AdminSession pool).

---

## P4a-10 — E2E integration tests

**Feishu-notify**: ✅ headline — "cc-voice and voice-e2e both round-trip end-to-end. Feishu-style inbound → VoiceASR (pool) → CC (tmux) → VoiceTTS (pool) → Feishu outbound. Simulated audio through stub engines; real Volcengine deferred to PR-5."
**Files**:
- Create `runtime/test/esr/integration/voice_e2e_test.exs`
- Create `runtime/test/esr/integration/cc_voice_test.exs`

Pattern mirrors `cc_e2e_test.exs`: load the voice fixture, spawn the session via `Esr.SessionRouter.create_session/1`, inject a simulated voice frame at the ChatProxy boundary, observe chunks surfacing at the outbound mock.

### Step 1 — `voice_e2e` integration

`runtime/test/esr/integration/voice_e2e_test.exs`:

```elixir
defmodule Esr.Integration.VoiceE2ETest do
  @moduledoc """
  P4a-10 — end-to-end for the `voice-e2e` agent.

  Flow:
    FeishuAppAdapter (simulated inbound audio frame)
      → FeishuChatProxy (session_id hit via SessionRegistry)
      → VoiceE2E (per-session, owns voice_e2e Python sidecar)
      → streams {:voice_chunk, _, seq} + :voice_end back to subscriber

  Subscriber is the test pid (via injecting VoiceE2E's :subscriber at
  spawn time through a test hook in SessionRouter.spawn_args/2 or
  via :sys.replace_state/2 on the spawned VoiceE2E).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  @fixture Path.expand("../fixtures/agents/voice.yaml", __DIR__)

  setup do
    assert is_pid(Process.whereis(Esr.SessionRegistry))
    assert is_pid(Process.whereis(Esr.AdminSessionProcess))

    :ok = Esr.SessionRegistry.load_agents(@fixture)

    # "*" grants everything so cap checks pass.
    snap = Esr.Capabilities.Grants.snapshot_for(Esr.Capabilities.Grants, "ou_test")
    on_exit(fn -> Esr.Capabilities.Grants.replace_for(Esr.Capabilities.Grants, "ou_test", snap) end)

    Esr.Capabilities.Grants.grant(Esr.Capabilities.Grants, %{
      principal_id: "ou_test",
      permissions: ["*"]
    })

    :ok
  end

  test "voice-e2e session receives stream_chunks + :voice_end" do
    {:ok, sid} =
      Esr.SessionRouter.create_session(%{
        agent: "voice-e2e",
        principal_id: "ou_test",
        chat_id: "chat_v1",
        thread_id: "thr_v1"
      })

    # Look up VoiceE2E pid via SessionRegistry refs.
    {:ok, ^sid, refs} = Esr.SessionRegistry.lookup_by_chat_thread("chat_v1", "thr_v1")
    voice_pid = refs[:voice_e2e]
    assert is_pid(voice_pid)

    # Patch the subscriber field to the test pid so chunks land here.
    :sys.replace_state(voice_pid, fn s -> %{s | subscriber: self()} end)

    :ok = Esr.Peers.VoiceE2E.turn(voice_pid, "aGVsbG8=")

    for seq <- 0..2, do: assert_receive({:voice_chunk, _, ^seq}, 3_000)
    assert_receive :voice_end, 3_000

    :ok = Esr.SessionRouter.end_session(sid)
  end
end
```

### Step 2 — `cc_voice` integration

`runtime/test/esr/integration/cc_voice_test.exs` — exercises the three-leg chain: VoiceASRProxy → CCProcess (stubbed handler) → VoiceTTSProxy. Test asserts:
- ASR proxy returns `"audio:8"` for an 8-byte b64 input via the pool.
- CCProcess's stubbed handler receives `{:text, "audio:8"}` and returns `[%{"type" => "reply", "text" => "ack"}]`.
- VoiceTTSProxy returns base64-encoded `"ack"` via the pool.

Exact wiring mirrors `cc_e2e_test.exs`'s "inject directly at the peer boundary" style because the same forward-only `build_neighbors/1` drift applies here.

### Step 3 — run

```bash
mix test test/esr/integration/voice_e2e_test.exs test/esr/integration/cc_voice_test.exs --only integration
```

Expected: 2 integration tests green.

### Step 4 — Feishu notification

> PR-4a 头条：cc-voice 与 voice-e2e 会话端到端打通。模拟音频输入 → VoiceASR (pool) → CC (tmux) → VoiceTTS (pool) → 模拟音频输出；streaming 的 voice-e2e 也验证了 3 chunk + stream_end 分帧。stub engine 下 hermetic，CI 不依赖 Volcengine。

**Acceptance**:
- Both integration tests green with `mix test --only integration`.
- Full `mix test` still green (no new failures).
- Killing the BEAM mid-session causes all Python voice sidecars to exit within 10s (inherited from `Esr.PyProcess` contract; can verify by extending `os_cleanup_test.exs` in PR-5).

---

## P4a-11 — "Delete `py/voice_gateway/`" (NO-OP deletion task)

**Feishu-notify**: no.
**Files**:
- Create `docs/notes/voice-gateway-never-materialized.md` (tombstone doc)
- Verify (grep-assert) no references to `voice_gateway` remain outside docs.

### Rationale

The plan's line 2303 says "Delete `py/voice_gateway/`". Inspection of the current worktree shows **no such directory ever existed**; the monolith described in spec §8.1 was a planning-time scaffold that got skipped — the refactor started with the three-sidecar layout directly.

### Step 1 — confirm absence

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor
[ ! -d py/voice_gateway ] && echo "confirmed absent"
```

Expected: `confirmed absent`.

### Step 2 — grep-assert no stray references

```bash
rg -l 'voice_gateway|voice-gateway' | rg -v 'docs/superpowers|docs/notes'
```

Expected: empty output. Any hits → either references need updating or the spec needs a new tombstone.

### Step 3 — tombstone doc

`docs/notes/voice-gateway-never-materialized.md`:

```markdown
# voice-gateway: never materialized

**Date**: 2026-04-23 (PR-4a)
**Status**: documented absence; no code deletion performed.

The plan's §PR-4a outline (`2026-04-22-peer-session-refactor-implementation.md`
line 2303, P4a-12) calls for "delete `py/voice_gateway/`". Inspection at
PR-4a expansion time confirmed the directory never existed in the worktree —
the three-sidecar layout (`voice_asr/`, `voice_tts/`, `voice_e2e/`)
landed directly without going through a monolithic intermediate.

Spec §8.1/§8.4 describe the monolith's decomposition as if it had existed;
those sections remain accurate as **design intent**, and the sidecars
implemented in PR-4a match the final shape. The "delete the monolith"
line in the plan is therefore a no-op and is tombstoned here for
traceability.

No action required at merge time. Future readers of the plan should
consult this note before assuming a monolith was deleted.
```

### Step 4 — commit

Include this doc in the PR-4a commit series (not a separate PR).

**Acceptance**:
- `py/voice_gateway/` does not exist.
- `rg voice_gateway` returns matches only in `docs/` + this tombstone.
- Spec sections §8.1/§8.4 remain untouched (they describe design intent).

---

## P4a-12 — Open PR-4a draft

**Feishu-notify**: ✅ PR opened.
**Files**: none; uses `gh pr create`.

### Step 1 — final local sanity

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor
cd py && uv run pytest tests/voice/ && cd ..
cd runtime && mix compile --warnings-as-errors && mix test && cd ..
```

Expected: Python 7 tests green; Elixir full suite green (including voice integration tests with `--include integration` if the mix.exs alias excludes them by default).

### Step 2 — push

```bash
git push -u origin feature/peer-session-refactor
```

### Step 3 — open draft PR

```bash
gh pr create --draft --title "PR-4a: voice-gateway split (voice-asr / voice-tts / voice-e2e sidecars + Elixir peers + cc-voice agent)" --body "$(cat <<'EOF'
## Summary

- Adds three Python sidecars (`voice_asr`, `voice_tts`, `voice_e2e`) with a shared `_voice_common` helper package. JSON-line stdin/stdout protocol per spec §8.1. Stub engines ship today; Volcengine integration deferred to PR-5.
- Adds Elixir peer wrappers `Esr.Peers.{VoiceASR,VoiceTTS,VoiceE2E}` + proxies `VoiceASRProxy` / `VoiceTTSProxy` using the PR-3 erlexec底座 via `Esr.PyProcess`. VoiceASR/TTS live in an AdminSession-scope pool (default size 4, capped at 128, optional `pools.yaml` override). VoiceE2E is per-session.
- Adds `cc-voice` and `voice-e2e` agents to the agents.yaml fixture + wires `SessionRouter` to handle them (`@stateful_impls` expanded, `build_ctx/2` / `spawn_args/2` clauses added).
- Integration tests cover: full cc-voice round-trip (stubbed audio → CC tmux → stubbed audio out), voice-e2e streaming (3 chunks + stream_end), pool acquire/release/exhaustion.
- The "delete `py/voice_gateway/`" plan step is a NO-OP — the monolith never existed; tombstoned in `docs/notes/voice-gateway-never-materialized.md`.

## Test plan

- [ ] `cd py && uv run pytest tests/voice/ -v` — 7 tests (3 sidecars × 1 round-trip + 4 protocol unit tests).
- [ ] `mix test` in `runtime/` — full suite green, no regressions.
- [ ] `mix test --only integration` — adds voice_e2e and cc_voice integration lanes.
- [ ] Manual: `/new-session --agent cc-voice --dir /tmp/test` via a live Feishu chat lands a session that responds to simulated audio (stub path).
- [ ] Manual: `/new-session --agent voice-e2e` spawns a streaming session.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

### Step 4 — Feishu notification

> PR-4a draft 已开：<gh pr url>。Voice-gateway split 完成：三个 Python sidecar + Elixir 包装 peer + cc-voice / voice-e2e agents。stub engine 下全绿；Volcengine 接入延到 PR-5。请 review。

**Acceptance**:
- `gh pr view` shows the draft with the body above.
- CI on the draft PR is green (pytest voice + mix test + mix compile --warnings-as-errors).

---

## P4a-13 — Wait for user review + merge

**Feishu-notify**: ✅ merged.
**Files**: none.

### Steps

1. Monitor PR comments/reviews via `gh pr view --comments`.
2. Address any feedback with additional commits (never amend).
3. On approval, `gh pr ready` → `gh pr merge --squash --delete-branch`.
4. Rebase local feature branch onto `main`:

```bash
git fetch origin && git checkout feature/peer-session-refactor && git rebase origin/main
```

5. Feishu notification: "PR-4a merged into main. voice-gateway split 完成。squash commit: <hash>."

**Acceptance**:
- PR is squash-merged.
- `git log origin/main --oneline | head -3` shows the PR-4a squash commit at HEAD.

---

## P4a-14 — Write PR-4a progress snapshot

**Feishu-notify**: ✅ final (can be combined with P4a-13 if same day).
**Files**: Create `docs/superpowers/progress/<merge-date>-pr4a-snapshot.md`.

Template: mirror `docs/superpowers/progress/2026-04-23-pr3-snapshot.md`. Sections:
- New public API surfaces (VoiceASR / VoiceTTS / VoiceE2E / VoiceASRProxy / VoiceTTSProxy / `Esr.Pools` / `Esr.AdminSession.bootstrap_voice_pools/1`).
- Decisions locked in during PR-4a:
  - `D4a-a`: voice-gateway monolith never existed; tombstoned.
  - `D4a-b`: default voice pool size 4 (capped at 128).
  - `D4a-c`: stub engines ship; Volcengine deferred to PR-5.
  - `D4a-d`: `pools.yaml` reader lands; writer CLI deferred.
- Tests added / known gaps.
- Tech debt carried forward (e.g., `cc-voice` outbound back-wiring still depends on the forward-only `build_neighbors/1` tech-debt row from PR-3).
- Feishu notification:

> PR-4a 收口快照已提交。下一步：PR-4b (adapter_runner split) — 与 PR-5 cleanup 并行走。参考: `docs/superpowers/progress/<date>-pr4a-snapshot.md`。

**Acceptance**:
- Snapshot exists at `docs/superpowers/progress/<merge-date>-pr4a-snapshot.md`.
- Committed on `main` (either via direct commit or follow-up trivial PR per repo convention — PR-3 landed its snapshot post-merge directly on `main`, same path here).

---

# Report

## Drift between plan outline and current code

| # | Plan outline says | Reality | Adjustment |
|---|---|---|---|
| 1 | Delete `py/voice_gateway/` (P4a-12 in plan) | Directory never existed in worktree; `find py/ -name voice_gateway` returns empty | Replaced with P4a-11 "tombstone doc" NO-OP. Spec §8.1/§8.4 untouched. |
| 2 | Plan assumes 15-task outline, counting delete-dir as file work | Merged deletion into a doc-only task; expanded to 15 tasks but with P4a-11 being near-zero code | Task count matches plan's 15 slots; only work nature changes. |
| 3 | Plan: "P4a-13 Open PR-4a draft + Feishu notify" | Kept but relabeled P4a-12 after the no-op merge with the old P4a-12. | Minor renumbering: P4a-0..14 instead of P4a-0..15. |
| 4 | Plan describes single `py/voice_asr/` package | Adopted `py/src/voice_asr/` because existing Python layout (per `py/pyproject.toml`) uses `where = ["src"]` for `setuptools.packages.find`. Putting packages under `py/` root (not `py/src/`) would require changing packages.find — strictly larger blast radius than necessary. | Expanded tasks use `py/src/<sidecar>/` paths. Spec §8.1's `py/voice_asr/` examples are accurate as design intent; file-path spec rows updated silently. |
| 5 | Outline says pool size 4-8 | Plan PR-3 outline D16 pinned default at 128; voice pools inherit unless `pools.yaml` overrides | Picked **4** as default for voice pools (hard-coded in `Esr.Pools.@defaults`), exposed via `pools.yaml` override. Matches PR-1 P1-11 capping semantics. |
| 6 | Outline assumes monolith-to-split refactor | No monolith to migrate from; sidecars are greenfield | Removed "parallel modules stay unused while monolith tests run" phase. |
| 7 | Proxy macro `@required_cap` strings for pools | PR-3 locked canonical `prefix:name/perm`; spec §3.5 for cc-voice says `peer_pool:voice_asr/acquire`, `peer_pool:voice_tts/acquire` | Already in spec and agents.yaml fixture; no change needed. |

## Spec-level contradictions

- **None blocking**. Spec §8.1's `py/voice_asr/` vs the actual greenfield `py/src/voice_asr/` layout is a non-semantic path difference (the module is still `voice_asr` and the CLI entry is still `python -m voice_asr`). Worth mentioning in the PR-4a snapshot so future readers don't get confused by the spec path literals.
- Minor: spec §8.1 still refers to MuonTrap in §8.3 excerpt; PR-3's erlexec migration already superseded this in `Esr.PyProcess` itself, so the §8.3 code block is outdated. Fixing §8.3 is out of scope for PR-4a (spec doc cleanup is PR-5's job per plan §PR-5 — "Regenerate `docs/architecture.md`"). Note in snapshot as PR-5 tech debt.
- Spec §4.1 VoiceASRProxy card says pool-acquire is one of **two** documented exceptions to static-target; spec §3.6 says **two exceptions** (voice pool + slash fallback). Consistent. The cc-voice agent yaml listing **both** VoiceASRProxy **and** VoiceTTSProxy means there are effectively **three** proxy instances that acquire (though only **one** proxy kind pattern). Spec wording (§3.6: "Two narrow exceptions — pool-acquire for voice peers (§4.1 VoiceASRProxy/VoiceTTSProxy) and the slash-handler fallback (§5.3)") is accurate: the exception pattern is "pool-acquire for voice peers (two modules, one pattern)", not "exactly two proxies".

## Tasks that should be reordered

- **None required** for the write-order above. The dependency DAG holds:
  - P4a-1 (shared helper) → P4a-{2,3,4} (Python sidecars, no ordering among them but P4a-4 notifies) → P4a-{5,6,8} (Elixir peer wrappers; P4a-5 and P4a-8 both depend only on the corresponding Python sidecar working) → P4a-7 (pool supervisor + AdminSession bootstrap; depends on P4a-5 for the worker module) → P4a-9 (agents.yaml + SessionRouter updates) → P4a-10 (E2E) → P4a-11..14 (ship).
- Optional: P4a-6 (proxies) can be parallelized with P4a-7 (pool sup) since the proxy code only needs the pool **name** (a compile-time atom), not the pool PID. But writing them as a linear chain avoids subagent coordination overhead for a single-engineer PR. Keep linear.

## Skills / dependencies not yet in place

- **erlexec-elixir skill** — already installed (`.claude/skills/erlexec-elixir/SKILL.md`). No gap.
- **`YamlElixir` dep for `Esr.Pools`** — already in `runtime/mix.exs` (used by `SessionRegistry`). No gap.
- **Python uv + pytest** — already configured. New test directory `py/tests/voice/` needs adding to `[tool.pytest.ini_options].testpaths` (P4a-1 step 3).
- **Volcengine API keys** — not needed for PR-4a because sidecars default to stub engines. Adding real engine calls is explicitly deferred to PR-5 (documented in `D4a-c`).
- **pools.yaml schema validator** — spec §8.1 mentions it; `Esr.Pools.pool_max/2` is a minimal reader (plus clamp). No writer CLI in PR-4a (PR-5).
- **PyProcess stream-frame support** — `py_process.ex` decodes each line as `{:py_reply, map}` regardless of `kind`. VoiceE2E pattern-matches on `kind` ∈ {"stream_chunk", "stream_end", "reply"} in its own `handle_info/2`. No PyProcess change needed.

---

### Critical Files for Implementation

- `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/py_process.ex`
- `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peer_pool.ex`
- `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/session_router.ex`
- `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/admin_session.ex`
- `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/py/pyproject.toml`
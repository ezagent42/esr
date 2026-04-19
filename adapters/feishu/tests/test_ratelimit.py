"""PRD 04 F15 — feishu rate limiting with exponential backoff."""

from __future__ import annotations

import asyncio
from typing import Any

import pytest

from esr.adapter import AdapterConfig


class _StubResponse:
    def __init__(
        self, code: int = 0, msg: str = "", message_id: str = ""
    ) -> None:
        self.code = code
        self.msg = msg
        self.data = type("D", (), {"message_id": message_id})()

    def success(self) -> bool:
        return self.code == 0


class _ScriptedMessageApi:
    """A stub im.v1.message whose create() cycles through scripted responses."""

    def __init__(self, responses: list[_StubResponse]) -> None:
        self._responses = list(responses)
        self.call_count = 0

    def create(self, request: object) -> _StubResponse:
        self.call_count += 1
        return self._responses.pop(0)


def _install_scripted_client(
    adapter_inst: object, responses: list[_StubResponse]
) -> _ScriptedMessageApi:
    scripted = _ScriptedMessageApi(responses)
    stub_client = type(
        "C",
        (),
        {"im": type("IM", (), {"v1": type("V", (), {"message": scripted})()})()},
    )()
    adapter_inst._lark_client = stub_client  # type: ignore[attr-defined]
    return scripted


async def test_rate_limit_retries_once_on_429(monkeypatch: pytest.MonkeyPatch) -> None:
    """A 429 followed by a 200 succeeds after one retry."""
    from esr_feishu.adapter import FeishuAdapter

    instance = FeishuAdapter.factory(
        "feishu-shared", AdapterConfig({"app_id": "a", "app_secret": "b"})
    )
    scripted = _install_scripted_client(
        instance,
        [
            _StubResponse(code=429, msg="rate limited"),
            _StubResponse(code=0, message_id="msg_after_retry"),
        ],
    )

    sleeps: list[float] = []

    async def _recording_sleep(delay: float) -> None:
        sleeps.append(delay)

    monkeypatch.setattr(asyncio, "sleep", _recording_sleep)

    ack = await instance.on_directive(
        "send_message", {"chat_id": "oc_x", "content": "hi"}
    )

    assert ack == {"ok": True, "result": {"message_id": "msg_after_retry"}}
    assert scripted.call_count == 2
    assert sleeps == [1.0]


async def test_rate_limit_gives_up_after_deadline(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Repeated 429s eventually time out with ok=False, error='timeout'."""
    from esr_feishu.adapter import FeishuAdapter

    instance = FeishuAdapter.factory(
        "feishu-shared", AdapterConfig({"app_id": "a", "app_secret": "b"})
    )
    scripted = _install_scripted_client(
        instance,
        [_StubResponse(code=429, msg="r") for _ in range(10)],
    )

    elapsed = 0.0

    async def _advance_clock(delay: float) -> None:
        nonlocal elapsed
        elapsed += delay

    monkeypatch.setattr(asyncio, "sleep", _advance_clock)

    async def _fake_time() -> float:  # unused — just documents intent
        return elapsed

    ack = await instance.on_directive(
        "send_message", {"chat_id": "oc_x", "content": "hi"}
    )
    assert ack["ok"] is False
    assert "timeout" in ack["error"]
    # Called at least twice before timing out (1s + 2s + ... until cumulative > 30s)
    assert scripted.call_count >= 4


async def test_non_429_errors_do_not_retry(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A non-429 lark error (e.g. 400) surfaces immediately without retry."""
    from esr_feishu.adapter import FeishuAdapter

    instance = FeishuAdapter.factory(
        "feishu-shared", AdapterConfig({"app_id": "a", "app_secret": "b"})
    )
    scripted = _install_scripted_client(
        instance, [_StubResponse(code=400, msg="bad request")]
    )

    sleeps: list[float] = []

    async def _recording_sleep(delay: float) -> None:
        sleeps.append(delay)

    monkeypatch.setattr(asyncio, "sleep", _recording_sleep)

    ack = await instance.on_directive(
        "send_message", {"chat_id": "oc_x", "content": "hi"}
    )

    assert ack["ok"] is False
    assert scripted.call_count == 1
    assert sleeps == []

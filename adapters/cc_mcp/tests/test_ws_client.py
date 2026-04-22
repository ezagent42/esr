import asyncio

import pytest

from esr_cc_mcp.ws_client import EsrWSClient, compute_backoff


def test_current_url_with_string_source() -> None:
    """String URLs are frozen at construction (legacy behaviour)."""
    client = EsrWSClient(
        url="ws://127.0.0.1:4001",
        session_id="s1",
        workspace="w1",
        chats=[],
    )
    assert client._current_url() == "ws://127.0.0.1:4001"


def test_current_url_with_callable_source_re_invokes() -> None:
    """Callable URLs are re-invoked each time — so EsrWSClient's
    reconnect loop follows port-file changes after launchctl kickstart
    (Task 8 DI-3)."""
    ports = iter(["ws://127.0.0.1:4001", "ws://127.0.0.1:5555", "ws://127.0.0.1:7070"])
    client = EsrWSClient(
        url=lambda: next(ports),
        session_id="s1",
        workspace="w1",
        chats=[],
    )
    assert client._current_url() == "ws://127.0.0.1:4001"
    assert client._current_url() == "ws://127.0.0.1:5555"
    assert client._current_url() == "ws://127.0.0.1:7070"


def test_backoff_has_jitter_and_is_bounded() -> None:
    # spec §6.2b: delay = min(30, 2^attempt) * (0.5 + random())
    delays = [compute_backoff(attempt, rng=lambda: 0.5) for attempt in range(0, 10)]
    # rng=0.5 → factor=1.0 — so delay is exactly min(30, 2^attempt)
    assert delays[0] == 1.0
    assert delays[3] == 8.0
    assert delays[10 - 1] >= 30.0 - 0.001  # capped


def test_compute_backoff_ranges_with_rng() -> None:
    low = compute_backoff(5, rng=lambda: 0.0)   # 2^5=32 capped to 30; 30 * 0.5 = 15
    high = compute_backoff(5, rng=lambda: 1.0)  # 30 * 1.5 = 45
    assert low == pytest.approx(15.0)
    assert high == pytest.approx(45.0)

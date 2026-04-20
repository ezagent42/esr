import asyncio

import pytest

from esr_cc_mcp.ws_client import EsrWSClient, compute_backoff


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
